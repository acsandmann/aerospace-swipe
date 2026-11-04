#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "aerospace.h"
#include "config.h"
#import "event_tap.h"
#include "haptic.h"
#include <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <pthread.h>

static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static gesture_ctx g_gesture_ctx = { 0 };
static CFMutableDictionaryRef g_tracks = NULL;

static void switch_workspace(const char* ws)
{
	if (g_config.skip_empty || g_config.wrap_around) {
		char* workspaces = aerospace_list_workspaces(g_aerospace, !g_config.skip_empty);
		if (!workspaces) {
			fprintf(stderr, "Error: Unable to retrieve workspace list.\n");
			return;
		}
		char* result = aerospace_workspace(g_aerospace, g_config.wrap_around, ws, workspaces);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace to '%s'.\n", ws);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(workspaces);
		free(result);
	} else {
		char* result = aerospace_switch(g_aerospace, ws);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace: '%s'\n", result);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(result);
	}

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);
}

static void run_command(const char* command)
{
	if (!command || !*command)
		return;

	char* result = aerospace_run(g_aerospace, command);
	if (result) {
		fprintf(stderr, "Error: Failed to run '%s': %s\n", command, result);
	} else {
		printf("Ran '%s' successfully.\n", command);
	}
	free(result);

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);
}

static bool vertical_enabled(void)
{
	return g_config.swipe_up[0] || g_config.swipe_down[0];
}

// Pick the component of a (x, y) pair that lies along the given axis.
static inline float along(gesture_axis axis, float x, float y)
{
	return axis == AXIS_Y ? y : x;
}

static void reset_gesture_state(gesture_ctx* ctx)
{
	ctx->state = GS_IDLE;
	ctx->last_fire_dir = 0;
}

static void arm_gesture(gesture_ctx* ctx, gesture_axis axis, float avg_x, float avg_y, float avg_vel)
{
	ctx->state = GS_ARMED;
	ctx->axis = axis;
	ctx->start_x = avg_x;
	ctx->start_y = avg_y;
	ctx->peak_vel = avg_vel;
	ctx->dir = (avg_vel >= 0) ? 1 : -1;
}

static void fire_gesture(gesture_ctx* ctx, int direction)
{
	if (direction == ctx->last_fire_dir)
		return;

	ctx->last_fire_dir = direction;
	ctx->state = GS_COMMITTED;
	ctx->axis_locked = true;
	gesture_axis axis = ctx->axis;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		if (axis == AXIS_Y)
			run_command(direction > 0 ? g_config.swipe_up : g_config.swipe_down);
		else
			switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}

static void calculate_touch_averages(touch* touches, int count,
	float* avg_x, float* avg_y, float* avg_velx, float* avg_vely)
{
	*avg_x = *avg_y = *avg_velx = *avg_vely = 0;

	for (int i = 0; i < count; ++i) {
		*avg_x += touches[i].x;
		*avg_y += touches[i].y;
		*avg_velx += touches[i].velocity_x;
		*avg_vely += touches[i].velocity_y;
	}

	*avg_x /= count;
	*avg_y /= count;
	*avg_velx /= count;
	*avg_vely /= count;
}

static bool handle_committed_state(gesture_ctx* ctx, touch* touches, int count)
{
	bool all_ended = true;
	for (int i = 0; i < count; ++i) {
		if (touches[i].phase != END_PHASE) {
			all_ended = false;
			break;
		}
	}

	if (!count || all_ended) {
		reset_gesture_state(ctx);
		return true;
	}

	float avg_x, avg_y, avg_velx, avg_vely;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_velx, &avg_vely);

	float dp = along(ctx->axis, avg_x - ctx->start_x, avg_y - ctx->start_y);
	if ((dp * ctx->last_fire_dir) < 0 && fabsf(dp) >= g_config.min_travel) {
		arm_gesture(ctx, ctx->axis, avg_x, avg_y, along(ctx->axis, avg_velx, avg_vely));

		for (int i = 0; i < count; ++i) {
			ctx->base_x[i] = touches[i].x;
			ctx->base_y[i] = touches[i].y;
		}
	}

	return true;
}

static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_velx, float avg_vely)
{
	// Choose the axis from this frame's dominant finger motion. Vertical is
	// only a candidate when a vertical command is configured, so the
	// horizontal-only behaviour is unchanged by default. Once a gesture has
	// fired, the axis stays locked until a finger lifts so a pause followed
	// by a sideways twitch does not trigger the other axis.
	gesture_axis axis = AXIS_X;
	if (ctx->axis_locked) {
		axis = ctx->axis;
	} else if (vertical_enabled()) {
		float frame_dx = 0, frame_dy = 0;
		for (int i = 0; i < count; ++i) {
			frame_dx += touches[i].x - ctx->base_x[i];
			frame_dy += touches[i].y - ctx->base_y[i];
		}
		if (fabsf(frame_dy) > fabsf(frame_dx))
			axis = AXIS_Y;
	}

	float avg_vel = along(axis, avg_velx, avg_vely);
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float need = fast ? g_config.min_travel_fast : g_config.min_travel;

	bool moved = true;
	for (int i = 0; i < count && moved; ++i) {
		float pos = along(axis, touches[i].x, touches[i].y);
		float base = along(axis, ctx->base_x[i], ctx->base_y[i]);
		moved &= fabsf(pos - base) >= need;
	}

	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;
	float dp = along(axis, dx, dy); // travel along the gesture axis
	float ds = along(axis, dy, dx); // travel across it

	if (moved && (fast || (fabsf(dp) >= ACTIVATE_PCT && fabsf(dp) > fabsf(ds))))
		arm_gesture(ctx, axis, avg_x, avg_y, avg_vel);
}

static void handle_armed_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_velx, float avg_vely)
{
	gesture_axis axis = ctx->axis;
	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;
	float dp = along(axis, dx, dy);
	float ds = along(axis, dy, dx);

	if (fabsf(ds) > fabsf(dp)) {
		reset_gesture_state(ctx);
		return;
	}

	float avg_vel = along(axis, avg_velx, avg_vely);
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	int mismatch_count = 0;
	for (int i = 0; i < count; ++i) {
		float ddp = along(axis, touches[i].x - ctx->prev_x[i], touches[i].y - ctx->prev_y[i]);
		if (fabsf(ddp) < stepReq || (ddp * dp) < 0) {
			mismatch_count++;
			if (mismatch_count > g_config.swipe_tolerance) {
				reset_gesture_state(ctx);
				return;
			}
		}
	}

	if (fabsf(avg_vel) > fabsf(ctx->peak_vel)) {
		ctx->peak_vel = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}

	if (fabsf(avg_vel) >= g_config.velocity_pct) {
		fire_gesture(ctx, avg_vel > 0 ? 1 : -1);
	} else if (fabsf(dp) >= g_config.distance_pct && fabsf(avg_vel) <= g_config.velocity_pct * g_config.settle_factor) {
		fire_gesture(ctx, dp > 0 ? 1 : -1);
	}
}

static void gestureCallback(touch* touches, int count)
{
	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	for (int i = 0; i < count; ++i) {
		if (touches[i].phase == END_PHASE) {
			ctx->axis_locked = false;
			break;
		}
	}

	if (ctx->state == GS_COMMITTED) {
		if (handle_committed_state(ctx, touches, count))
			goto unlock;
	}

	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i) {
			ctx->prev_x[i] = ctx->base_x[i] = touches[i].x;
			ctx->prev_y[i] = ctx->base_y[i] = touches[i].y;
		}

		goto unlock;
	}

	float avg_x, avg_y, avg_velx, avg_vely;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_velx, &avg_vely);

	if (ctx->state == GS_IDLE) {
		handle_idle_state(ctx, touches, count, avg_x, avg_y, avg_velx, avg_vely);
	} else if (ctx->state == GS_ARMED) {
		handle_armed_state(ctx, touches, count, avg_x, avg_y, avg_velx, avg_vely);
	}

	for (int i = 0; i < count; ++i) {
		ctx->prev_x[i] = touches[i].x;
		ctx->prev_y[i] = touches[i].y;
		if (ctx->state == GS_IDLE) {
			ctx->base_x[i] = touches[i].x;
			ctx->base_y[i] = touches[i].y;
		}
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

static void process_touches(NSSet<NSTouch*>* touches)
{
	NSUInteger buf_capacity = touches.count > 0 ? touches.count : 4;
	touch* buf = malloc(sizeof(touch) * buf_capacity);
	NSUInteger i = 0;

	for (NSTouch* touch in touches) {
		if (touch.phase != (1 << 2)) {
			if (i >= buf_capacity) {
				buf_capacity *= 2;
				buf = realloc(buf, sizeof(touch) * buf_capacity);
			}
			buf[i++] = [TouchConverter convert_nstouch:touch];
		}
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(buf, (int)i);
		free(buf);
	});
}

static CGEventRef key_handler(__unused CGEventTapProxy proxy, CGEventType type,
	CGEventRef event, void* ref)
{
	struct event_tap* event_tap_ref = (struct event_tap*)ref;

	if (!AXIsProcessTrusted()) {
		NSLog(@"Accessibility permission lost, disabling tap.");
		event_tap_end(event_tap_ref);
		return event;
	}

	if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
		NSLog(@"Event-tap re-enabled.");
		CGEventTapEnable(event_tap_ref->handle, true);
		return event;
	}

	if (type != NSEventTypeGesture)
		return event;

	NSEvent* ev = [NSEvent eventWithCGEvent:event];
	NSSet<NSTouch*>* touches = ev.allTouches;

	if (!touches.count)
		return event;

	process_touches(touches);

	return event;
}

static void acquire_lockfile(void)
{
	char* user = getenv("USER");
	if (!user)
		printf("Error: User variable not set.\n"), exit(1);

	char buffer[256];
	snprintf(buffer, 256, "/tmp/aerospace-swipe-%s.lock", user);

	int handle = open(buffer, O_CREAT | O_WRONLY, 0600);
	if (handle == -1) {
		printf("Error: Could not create lock-file.\n");
		exit(1);
	}

	struct flock lockfd = {
		.l_start = 0,
		.l_len = 0,
		.l_pid = getpid(),
		.l_type = F_WRLCK,
		.l_whence = SEEK_SET
	};

	if (fcntl(handle, F_SETLK, &lockfd) == -1) {
		printf("Error: Could not acquire lock-file.\naerospace-swipe already running?\n");
		exit(1);
	}
}

void waitForAccessibilityAndRestart(void)
{
	while (!AXIsProcessTrusted()) {
		NSLog(@"Waiting for accessibility permission...");
		sleep(1);
	}

	NSLog(@"Accessibility permission granted. Restarting app...");

	NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
	[[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:bundlePath] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
	exit(0);
}

int main(int argc, const char* argv[])
{
	signal(SIGCHLD, SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	acquire_lockfile();

	@autoreleasepool {
		NSDictionary* options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};

		if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
			NSLog(@"Accessibility permission not granted. Prompting user...");
			AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				waitForAccessibilityAndRestart();
			});

			CFRunLoopRun();
		}

		NSLog(@"Accessibility permission granted. Continuing app initialization...");

		g_config = load_config();
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, swipe_left='%s', swipe_right='%s', swipe_up='%s', swipe_down='%s'",
			g_config.fingers,
			g_config.skip_empty ? "YES" : "NO",
			g_config.wrap_around ? "YES" : "NO",
			g_config.haptic ? "YES" : "NO",
			g_config.swipe_left,
			g_config.swipe_right,
			g_config.swipe_up,
			g_config.swipe_down);

		g_aerospace = aerospace_new(NULL);
		if (!g_aerospace) {
			fprintf(stderr, "Error: Failed to initialize Aerospace client.\n");
			exit(EXIT_FAILURE);
		}

		if (g_config.haptic) {
			g_haptic = haptic_open_default();
			if (!g_haptic)
				fprintf(stderr, "Warning: Failed to initialize haptic actuator. Continuing without haptics.\n");
		}

		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		event_tap_begin(&g_event_tap, key_handler);

		return NSApplicationMain(argc, argv);
	}
}

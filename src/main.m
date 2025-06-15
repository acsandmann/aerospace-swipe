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

static const CGFloat PALM_DISP = 0.025; // 2.5% pad from origin
static const CFTimeInterval PALM_AGE = 0.06; // 60ms before judgment
static const CGFloat PALM_VELOCITY = 0.1; // 10% of pad dimension per second

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

	if (g_config.haptic == true)
		haptic_actuate(g_haptic, 3);
}

static void reset_gesture_state(gesture_ctx* ctx)
{
	ctx->state = GS_IDLE;
	ctx->last_fire_dir = 0;
}

static void fire_gesture(gesture_ctx* ctx, int direction)
{
	if (direction == ctx->last_fire_dir)
		return;

	ctx->last_fire_dir = direction;
	ctx->state = GS_COMMITTED;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}

static void calculate_touch_averages(touch* touches, int count,
	float* avg_x, float* avg_y, float* avg_vel,
	float* min_x, float* max_x, float* min_y, float* max_y)
{
	*avg_x = *avg_y = *avg_vel = 0;
	*min_x = *min_y = 1;
	*max_x = *max_y = 0;

	for (int i = 0; i < count; ++i) {
		*avg_x += touches[i].x;
		*avg_y += touches[i].y;
		*avg_vel += touches[i].velocity;

		if (touches[i].x < *min_x)
			*min_x = touches[i].x;
		if (touches[i].x > *max_x)
			*max_x = touches[i].x;
		if (touches[i].y < *min_y)
			*min_y = touches[i].y;
		if (touches[i].y > *max_y)
			*max_y = touches[i].y;
	}

	*avg_x /= count;
	*avg_y /= count;
	*avg_vel /= count;
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

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	float dx = avg_x - ctx->start_x;
	if ((dx * ctx->last_fire_dir) < 0 && fabsf(dx) >= g_config.min_travel) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;

		for (int i = 0; i < count; ++i)
			ctx->base_x[i] = touches[i].x;
	}

	return true;
}

static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float need = fast ? g_config.min_travel_fast : g_config.min_travel;

	bool moved = true;
	for (int i = 0; i < count && moved; ++i)
		moved &= fabsf(touches[i].x - ctx->base_x[i]) >= need;

	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	if (moved && (fast || (fabsf(dx) >= ACTIVATE_PCT && fabsf(dx) > fabsf(dy)))) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}
}

// Handle armed state logic
static void handle_armed_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	// Reset if vertical movement exceeds horizontal
	if (fabsf(dy) > fabsf(dx)) {
		reset_gesture_state(ctx);
		return;
	}

	// Validate step requirements
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	for (int i = 0; i < count; ++i) {
		float ddx = touches[i].x - ctx->prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			reset_gesture_state(ctx);
			return;
		}
	}

	// Update peak velocity
	if (fabsf(avg_vel) > fabsf(ctx->peak_velx)) {
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}

	// Check firing conditions
	if (fabsf(avg_vel) >= g_config.velocity_pct) {
		fire_gesture(ctx, avg_vel > 0 ? 1 : -1);
	} else if (fabsf(dx) >= g_config.distance_pct && fabsf(avg_vel) <= g_config.velocity_pct * g_config.settle_factor) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
}

// Main gesture callback function
static void gestureCallback(touch* touches, int count)
{
	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	// Handle committed state
	if (ctx->state == GS_COMMITTED) {
		if (handle_committed_state(ctx, touches, count))
			goto unlock;
	}

	// Handle finger count mismatch
	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i)
			ctx->prev_x[i] = ctx->base_x[i] = touches[i].x;

		goto unlock;
	}

	// Calculate averages for current touches
	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	// Handle state-specific logic
	if (ctx->state == GS_IDLE) {
		handle_idle_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	} else if (ctx->state == GS_ARMED) {
		handle_armed_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	}

	// Update tracking arrays

	for (int i = 0; i < count; ++i) {
		ctx->prev_x[i] = touches[i].x;
		if (ctx->state == GS_IDLE)
			ctx->base_x[i] = touches[i].x;
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

static void mark_all_tracks_unseen(void)
{
	for (id k in (__bridge NSDictionary*)g_tracks) {
		finger_track* trk = (finger_track*)CFDictionaryGetValue(g_tracks, (__bridge const void*)k);
		trk->seen = false;
	}
}

static void update_or_create_track(NSTouch* touch, CFTimeInterval now)
{
	const void* key = (__bridge const void*)touch.identity;
	finger_track* trk = (finger_track*)CFDictionaryGetValue(g_tracks, key);
	CGPoint p = touch.normalizedPosition;

	if (!trk) {
		trk = calloc(1, sizeof(*trk));
		trk->start = trk->last = p;
		trk->t_start = trk->t_last = now;
		CFDictionarySetValue(g_tracks, key, trk);
	}

	CFTimeInterval dt = now - trk->t_last;
	CGFloat step = hypot(p.x - trk->last.x, p.y - trk->last.y);
	CGFloat vel = (dt > 0) ? (step / dt) : 0.0f;
	CGFloat disp = hypot(p.x - trk->start.x, p.y - trk->start.y);

	trk->last = p;
	trk->t_last = now;

	if (!trk->is_palm) {
		bool agedEnough = (now - trk->t_start) > PALM_AGE;
		bool trivialDisp = disp < PALM_DISP;
		bool slowEnough = vel < PALM_VELOCITY;

		if (agedEnough && trivialDisp && slowEnough)
			trk->is_palm = true;
	}

	trk->seen = true;
}

static void remove_unseen_tracks(void)
{
	NSMutableArray* dead = [NSMutableArray array];

	for (id k in (__bridge NSDictionary*)g_tracks) {
		finger_track* trk = (finger_track*)CFDictionaryGetValue(g_tracks, (__bridge const void*)k);
		if (!trk->seen)
			[dead addObject:k];
	}

	for (id k in dead) {
		free(CFDictionaryGetValue(g_tracks, (__bridge const void*)k));
		CFDictionaryRemoveValue(g_tracks, (__bridge const void*)k);
	}
}

static void update_tracks(NSSet<NSTouch*>* touches, CFTimeInterval now)
{
	mark_all_tracks_unseen();

	for (NSTouch* touch in touches) {
		update_or_create_track(touch, now);
	}

	remove_unseen_tracks();
}

static NSUInteger count_live_touches(NSSet<NSTouch*>* touches)
{
	NSUInteger live = 0;
	for (NSTouch* touch in touches) {
		finger_track* trk = CFDictionaryGetValue(g_tracks, (__bridge const void*)touch.identity);
		if (trk && !trk->is_palm)
			++live;
	}
	return live;
}

static void process_live_touches(NSSet<NSTouch*>* touches, NSUInteger live_count)
{
	touch* buf = malloc(sizeof(touch) * live_count);
	NSUInteger i = 0;

	for (NSTouch* touch in touches) {
		finger_track* trk = CFDictionaryGetValue(g_tracks, (__bridge const void*)touch.identity);
		if (trk && !trk->is_palm)
			buf[i++] = [TouchConverter convert_nstouch:touch];
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(buf, (int)live_count);
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

	update_tracks(touches, ev.timestamp);

	NSUInteger live_count = count_live_touches(touches);
	if (!live_count)
		return event;

	process_live_touches(touches, live_count);

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
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, swipe_left='%s', swipe_right='%s'",
			g_config.fingers,
			g_config.skip_empty ? "YES" : "NO",
			g_config.wrap_around ? "YES" : "NO",
			g_config.haptic ? "YES" : "NO",
			g_config.swipe_left,
			g_config.swipe_right);

		g_aerospace = aerospace_new(NULL);
		if (!g_aerospace) {
			fprintf(stderr, "Error: Failed to initialize Aerospace client.\n");
			exit(EXIT_FAILURE);
		}

		if (g_config.haptic && !(g_haptic = haptic_open_default())) {
			fprintf(stderr, "Error: Failed to initialize haptic actuator.\n");
			aerospace_close(g_aerospace);
			exit(EXIT_FAILURE);
		}

		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		event_tap_begin(&g_event_tap, key_handler);

		return NSApplicationMain(argc, argv);
	}
}

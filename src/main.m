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

// --- raw MultitouchSupport detection -----------------------------------
// On macOS 26.3 a CGEvent tap no longer carries multi-touch data (each
// gesture event exposes at most one NSTouch), so the event-tap path can
// never see the configured finger count. Raw contact frames from the
// private MultitouchSupport framework still deliver every finger with
// position and velocity; feed those into the same gesture engine.
typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint pos, vel; } mtReadout;
typedef struct {
	int frame;
	double timestamp;
	int identifier, state, foo3, foo4;
	mtReadout normalized;
	float size;
	int zero1;
	float angle, majorAxis, minorAxis;
	mtReadout mm;
	int zero2[2];
	float unk2;
} MTFinger;
typedef void* MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int, MTFinger*, int, double, int);
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);

typedef uint64_t IOHIDRequestType;
enum { kIOHIDRequestTypeListenEvent = 1 };
extern bool IOHIDRequestAccess(IOHIDRequestType);

static CFArrayRef g_mt_devices = NULL;

// AeroSpace numbers monitors by arrangement (left to right), so sorting
// CG displays by x-origin gives the same ids. Returns 0 on failure.
static int monitor_under_cursor(void)
{
	CGEventRef ev = CGEventCreate(NULL);
	if (!ev)
		return 0;
	CGPoint p = CGEventGetLocation(ev);
	CFRelease(ev);

	CGDirectDisplayID ids[8];
	uint32_t n = 0;
	if (CGGetActiveDisplayList(8, ids, &n) != kCGErrorSuccess || !n)
		return 0;

	// sort by x-origin (tiny n, insertion sort)
	for (uint32_t i = 1; i < n; ++i)
		for (uint32_t j = i; j > 0; --j)
			if (CGDisplayBounds(ids[j]).origin.x < CGDisplayBounds(ids[j - 1]).origin.x) {
				CGDirectDisplayID t = ids[j];
				ids[j] = ids[j - 1];
				ids[j - 1] = t;
			}

	for (uint32_t i = 0; i < n; ++i)
		if (CGRectContainsPoint(CGDisplayBounds(ids[i]), p))
			return (int)i + 1;
	return 0;
}

// Step to the neighbouring workspace of the monitor the cursor is on
// (native-Spaces semantics: the swipe acts where the pointer is, never
// on the other monitor). Returns false so the caller can fall back to
// focused-monitor stepping when the cursor's monitor or its visible
// workspace can't be resolved.
static bool switch_on_cursor_monitor(const char* ws)
{
	int mon = monitor_under_cursor();
	if (!mon)
		return false;
	int dir = strcmp(ws, "next") == 0 ? 1 : strcmp(ws, "prev") == 0 ? -1 : 0;
	if (!dir)
		return false;

	char mon_str[16];
	snprintf(mon_str, sizeof mon_str, "%d", mon);

	const char* vis_args[] = { "list-workspaces", "--monitor", mon_str, "--visible" };
	char* visible = aerospace_exec(g_aerospace, vis_args, 4, "stdout");
	if (!visible)
		return false;
	visible[strcspn(visible, "\r\n")] = '\0';

	const char* list_args[] = { "list-workspaces", "--monitor", mon_str, "--empty", "no" };
	char* list = aerospace_exec(g_aerospace, list_args, g_config.skip_empty ? 5 : 3, "stdout");
	if (!list) {
		free(visible);
		return false;
	}

	char* names[64];
	int count = 0, cur = -1;
	for (char* tok = strtok(list, "\r\n"); tok && count < 64; tok = strtok(NULL, "\r\n")) {
		if (!*tok)
			continue;
		names[count] = tok;
		if (strcmp(tok, visible) == 0)
			cur = count;
		count++;
	}

	bool ok = false;
	if (count > 0 && cur >= 0) {
		int next = cur + dir;
		if (g_config.wrap_around)
			next = (next + count) % count;
		if (next >= 0 && next < count && next != cur) {
			const char* sw_args[] = { "workspace", names[next] };
			char* result = aerospace_exec(g_aerospace, sw_args, 2, NULL);
			free(result);
			printf("Switched monitor %s to workspace '%s'.\n", mon_str, names[next]);
			ok = true;
		} else {
			ok = true; // at the edge without wrap: consume the swipe, do nothing
		}
	}

	free(visible);
	free(list);
	return ok;
}

static void switch_workspace(const char* ws)
{
	if (g_config.cursor_monitor && switch_on_cursor_monitor(ws)) {
		if (g_config.haptic && g_haptic)
			haptic_actuate(g_haptic, 3);
		return;
	}

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

static void handle_armed_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	if (fabsf(dy) > fabsf(dx)) {
		reset_gesture_state(ctx);
		return;
	}

	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	int mismatch_count = 0;
	for (int i = 0; i < count; ++i) {
		float ddx = touches[i].x - ctx->prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			mismatch_count++;
			if (mismatch_count > g_config.swipe_tolerance) {
				reset_gesture_state(ctx);
				return;
			}
		}
	}

	if (fabsf(avg_vel) > fabsf(ctx->peak_velx)) {
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}

	if (fabsf(avg_vel) >= g_config.velocity_pct) {
		fire_gesture(ctx, avg_vel > 0 ? 1 : -1);
	} else if (fabsf(dx) >= g_config.distance_pct && fabsf(avg_vel) <= g_config.velocity_pct * g_config.settle_factor) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
}

static void gestureCallback(touch* touches, int count)
{
	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	if (ctx->state == GS_COMMITTED) {
		if (handle_committed_state(ctx, touches, count))
			goto unlock;
	}

	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i)
			ctx->prev_x[i] = ctx->base_x[i] = touches[i].x;

		goto unlock;
	}

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	if (ctx->state == GS_IDLE) {
		handle_idle_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	} else if (ctx->state == GS_ARMED) {
		handle_armed_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	}

	for (int i = 0; i < count; ++i) {
		ctx->prev_x[i] = touches[i].x;
		if (ctx->state == GS_IDLE)
			ctx->base_x[i] = touches[i].x;
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

// MT finger states: 1 start, 2 hover, 3 make, 4 touching, 5 break,
// 6 linger, 7 leave. Count fingers that are on the surface (3-5);
// lift-off shows up as the count dropping, which the engine already
// treats as gesture end.
static int mt_contact_callback(int device, MTFinger* data, int nFingers,
	double timestamp, int frame)
{
	(void)device;
	(void)frame;

	int cap = nFingers > 0 ? nFingers : 1;
	touch* buf = malloc(sizeof(touch) * cap);
	int n = 0;

	for (int i = 0; i < nFingers; ++i) {
		if (data[i].state < 3 || data[i].state > 5)
			continue;
		buf[n].x = data[i].normalized.pos.x;
		buf[n].y = data[i].normalized.pos.y;
		buf[n].velocity = data[i].normalized.vel.x;
		buf[n].timestamp = timestamp;
		buf[n].phase = 1 << 1; // moved; lift-off is signaled by count dropping
		buf[n].is_palm = false;
		n++;
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(buf, n);
		free(buf);
	});

	return 0;
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

		if (g_config.haptic) {
			g_haptic = haptic_open_default();
			if (!g_haptic)
				fprintf(stderr, "Warning: Failed to initialize haptic actuator. Continuing without haptics.\n");
		}

		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		// Raw contact frames need the Input Monitoring permission
		// (this prompts on first run) and a running run loop, which
		// NSApplicationMain provides below.
		IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);

		g_mt_devices = MTDeviceCreateList();
		CFIndex mt_count = g_mt_devices ? CFArrayGetCount(g_mt_devices) : 0;
		if (!mt_count) {
			fprintf(stderr, "Error: no multitouch devices found.\n");
			exit(EXIT_FAILURE);
		}
		for (CFIndex i = 0; i < mt_count; ++i) {
			MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_mt_devices, i);
			MTRegisterContactFrameCallback(dev, mt_contact_callback);
			MTDeviceStart(dev, 0);
		}
		NSLog(@"Raw multitouch detection active on %ld device(s).", (long)mt_count);

		return NSApplicationMain(argc, argv);
	}
}

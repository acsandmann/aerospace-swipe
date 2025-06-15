#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "aerospace.h"
#include "config.h"
#import "event_tap.h"
#include "haptic.h"
#include <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <pthread.h>

#define MAX_TOUCHES 16
#define ACTIVATE_PCT 0.05f
#define FAST_VEL_FACTOR 0.80f // determine if a swipe is fast based on velocity
#define END_PHASE 8 // NSTouchPhase

static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static gesture_state g_gesture_state = GESTURE_STATE_IDLE;
static CFMutableDictionaryRef g_tracks;

static float g_start_x, g_start_y;
static float g_peak_vel_x;
static int g_last_fire_dir = 0;
static float g_prev_x[MAX_TOUCHES];
static float g_base_x[MAX_TOUCHES];

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

static void reset_gesture_state()
{
	g_gesture_state = GESTURE_STATE_IDLE;
	g_last_fire_dir = 0;
}

static void fire_swipe_action(int direction)
{
	if (direction == g_last_fire_dir) {
		return;
	}
	g_last_fire_dir = direction;
	g_gesture_state = GESTURE_STATE_COMMITTED;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}

static touch_data get_average_touch_data(const touch* touches, int touch_count)
{
	touch_data data = { 0 };
	if (touch_count == 0)
		return data;

	for (int i = 0; i < touch_count; ++i) {
		data.avg_x += touches[i].x;
		data.avg_y += touches[i].y;
		data.avg_vel_x += touches[i].velocity;
	}
	data.avg_x /= touch_count;
	data.avg_y /= touch_count;
	data.avg_vel_x /= touch_count;
	data.count = touch_count;
	return data;
}

static void handle_state_idle(const touch_data* data, const touch* touches)
{
	bool is_fast = fabsf(data->avg_vel_x) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float required_travel = is_fast ? g_config.min_travel_fast : g_config.min_travel;

	bool moved_enough = true;
	for (int i = 0; i < data->count; ++i) {
		if (fabsf(touches[i].x - g_base_x[i]) < required_travel) {
			moved_enough = false;
			break;
		}
	}

	float dx = data->avg_x - g_start_x;
	float dy = data->avg_y - g_start_y;

	if (moved_enough && (is_fast || (fabsf(dx) >= ACTIVATE_PCT && fabsf(dx) > fabsf(dy)))) {
		g_gesture_state = GESTURE_STATE_ARMED;
		g_start_x = data->avg_x;
		g_start_y = data->avg_y;
		g_peak_vel_x = data->avg_vel_x;
	}
}

static void handle_state_armed(const touch_data* data, const touch* touches)
{
	float dx = data->avg_x - g_start_x;
	float dy = data->avg_y - g_start_y;

	if (fabsf(dy) > fabsf(dx)) {
		reset_gesture_state();
		return;
	}

	bool is_fast = fabsf(data->avg_vel_x) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float required_step = is_fast ? g_config.min_step_fast : g_config.min_step;
	for (int i = 0; i < data->count; ++i) {
		float finger_dx = touches[i].x - g_prev_x[i];
		if (fabsf(finger_dx) < required_step || (finger_dx * dx) < 0) {
			reset_gesture_state();
			return;
		}
	}

	if (fabsf(data->avg_vel_x) > fabsf(g_peak_vel_x)) {
		g_peak_vel_x = data->avg_vel_x;
	}

	if (fabsf(data->avg_vel_x) >= g_config.velocity_pct) {
		fire_swipe_action(data->avg_vel_x > 0 ? 1 : -1);
	} else if (fabsf(dx) >= g_config.distance_pct && fabsf(data->avg_vel_x) <= g_config.velocity_pct * g_config.settle_factor) {
		fire_swipe_action(dx > 0 ? 1 : -1);
	}
}

static void handle_state_committed(const touch_data* data, const touch* touches)
{
	bool all_touches_ended = true;
	for (int i = 0; i < data->count; ++i) {
		if (touches[i].phase != END_PHASE) {
			all_touches_ended = false;
			break;
		}
	}
	if (data->count == 0 || all_touches_ended) {
		reset_gesture_state();
		return;
	}

	float dx = data->avg_x - g_start_x;

	if ((dx * g_last_fire_dir) < 0 && fabsf(dx) >= g_config.min_travel) {
		g_gesture_state = GESTURE_STATE_ARMED;
		g_start_x = data->avg_x;
		g_start_y = data->avg_y;
		g_peak_vel_x = data->avg_vel_x;
		for (int i = 0; i < data->count; ++i) {
			g_base_x[i] = touches[i].x;
		}
	}
}

static void gestureCallback(touch* touches, int touch_count)
{
	pthread_mutex_lock(&g_gesture_mutex);

	if (touch_count != g_config.fingers) {
		if (g_gesture_state == GESTURE_STATE_ARMED) {
			reset_gesture_state();
		}
		for (int i = 0; i < touch_count; ++i) {
			g_base_x[i] = g_prev_x[i] = touches[i].x;
		}
		goto unlock;
	}

	touch_data touch_data = get_average_touch_data(touches, touch_count);

	switch (g_gesture_state) {
	case GESTURE_STATE_IDLE:
		handle_state_idle(&touch_data, touches);
		break;
	case GESTURE_STATE_ARMED:
		handle_state_armed(&touch_data, touches);
		break;
	case GESTURE_STATE_COMMITTED:
		handle_state_committed(&touch_data, touches);
		break;
	}

	for (int i = 0; i < touch_count; ++i) {
		g_prev_x[i] = touches[i].x;
		if (g_gesture_state == GESTURE_STATE_IDLE) {
			g_base_x[i] = touches[i].x;
		}
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

static void update_tracks(NSSet<NSTouch*>* touches, CFTimeInterval now)
{
	for (id key in (__bridge NSDictionary*)g_tracks) {
		((finger_track*)CFDictionaryGetValue(g_tracks, (__bridge const void*)key))->seen = false;
	}

	for (NSTouch* t in touches) {
		const void* key = (__bridge const void*)t.identity;
		finger_track* track = (finger_track*)CFDictionaryGetValue(g_tracks, key);
		CGPoint p = t.normalizedPosition;

		if (!track) {
			track = calloc(1, sizeof(finger_track));
			track->start_pos = track->last_pos = p;
			track->start_time = track->last_time = now;
			CFDictionarySetValue(g_tracks, key, track);
		}

		// Calculate movement since the last frame.
		CFTimeInterval dt = now - track->last_time;
		CGFloat step = hypot(p.x - track->last_pos.x, p.y - track->last_pos.y);
		CGFloat velocity = (dt > 0) ? (step / dt) : 0.0f;
		CGFloat displacement = hypot(p.x - track->start_pos.x, p.y - track->start_pos.y);

		track->last_pos = p;
		track->last_time = now;

		if (!track->is_palm) {
			bool is_old_enough = (now - track->start_time) > g_config.palm_age;
			bool has_not_moved_far = displacement < g_config.palm_disp;
			bool is_slow_enough = velocity < g_config.palm_velocity;

			if (is_old_enough && has_not_moved_far && is_slow_enough) {
				track->is_palm = true;
			}
		}
		track->seen = true;
	}

	const void* dead_keys[MAX_TOUCHES];
	int dead_count = 0;

	for (id key in (__bridge NSDictionary*)g_tracks) {
		if (!((finger_track*)CFDictionaryGetValue(g_tracks, key))->seen) {
			dead_keys[dead_count++] = (__bridge const void*)key;
		}
	}

	for (int i = 0; i < dead_count; i++) {
		free(CFDictionaryGetValue(g_tracks, dead_keys[i]));
		CFDictionaryRemoveValue(g_tracks, dead_keys[i]);
	}
}

static CGEventRef key_handler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* ref)
{
	if (!AXIsProcessTrusted()) {
		NSLog(@"Accessibility permission lost, disabling tap.");
		event_tap_end((struct event_tap*)ref);
		return event;
	}

	if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
		NSLog(@"Event-tap re-enabled.");
		CGEventTapEnable(((struct event_tap*)ref)->handle, true); // Assumes struct event_tap has a 'handle'
		return event;
	}

	if (type != NSEventTypeGesture) {
		return event;
	}

	NSEvent* ev = [NSEvent eventWithCGEvent:event];
	NSSet<NSTouch*>* all_touches = ev.allTouches;
	if (all_touches.count == 0) {
		return event;
	}

	update_tracks(all_touches, ev.timestamp);

	NSUInteger live_touch_count = 0;
	for (NSTouch* t in all_touches) {
		finger_track* track = CFDictionaryGetValue(g_tracks, (__bridge const void*)t.identity);
		if (track && !track->is_palm) {
			live_touch_count++;
		}
	}

	if (live_touch_count == 0) {
		return event;
	}

	touch* live_touches_buf = malloc(sizeof(touch) * live_touch_count);
	NSUInteger i = 0;
	for (NSTouch* t in all_touches) {
		finger_track* track = CFDictionaryGetValue(g_tracks, (__bridge const void*)t.identity);
		if (track && !track->is_palm) {
			live_touches_buf[i++] = [TouchConverter convert_nstouch:t];
		}
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(live_touches_buf, (int)live_touch_count);
		free(live_touches_buf);
	});

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
			&kCFTypeDictionaryKeyCallBacks, // retain keys
			NULL); // leave values alone

		event_tap_begin(&g_event_tap, key_handler);

		return NSApplicationMain(argc, argv);
	}
}

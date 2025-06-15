#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "aerospace.h"
#include "config.h"
#import "event_tap.h"
#include "haptic.h"
#include <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <Foundation/Foundation.h>
#include <pthread.h>

static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_gesture_q = NULL;
static gesture_context g_gesture_ctx = { 0 };
static CFMutableDictionaryRef g_finger_tracks;

static const float PALM_VELOCITY_DECAY = 0.9f;
static const float PALM_JITTER_THRESHOLD = 0.001f; // min movement to not be jitter

static inline float smooth_velocity(float new_vel)
{
	g_gesture_ctx.velocity_history[g_gesture_ctx.velocity_history_idx] = new_vel;
	g_gesture_ctx.velocity_history_idx = (g_gesture_ctx.velocity_history_idx + 1) % 3;

	float sum = 0.0f;
	int count = 0;
	for (int i = 0; i < 3; ++i) {
		if (g_gesture_ctx.velocity_history[i] != 0.0f) {
			sum += g_gesture_ctx.velocity_history[i];
			++count;
		}
	}

	return fmaxf(fmaxf(g_gesture_ctx.velocity_history[0],
					 g_gesture_ctx.velocity_history[1]),
		g_gesture_ctx.velocity_history[2]);
}

static inline float calculate_distance(CGPoint p1, CGPoint p2)
{
	float dx = p1.x - p2.x;
	float dy = p1.y - p2.y;
	return sqrtf(dx * dx + dy * dy);
}

static bool update_palm_detection(finger_track* track, CGPoint current_pos, CFTimeInterval now)
{
	if (track->palm_check_done) {
		return track->is_palm;
	}

	float step_distance = calculate_distance(current_pos, track->last_pos);
	float total_displacement = calculate_distance(current_pos, track->start_pos);
	CFTimeInterval dt = now - track->last_time;
	float current_velocity = (dt > 0) ? (step_distance / dt) : 0.0f;

	track->total_distance += step_distance;
	track->max_velocity = fmaxf(track->max_velocity, current_velocity);

	if (step_distance < PALM_JITTER_THRESHOLD) {
		track->stationary_frames++;
	} else {
		track->stationary_frames = 0;
	}

	// decay max vel over time to handle temporary spikes
	float age = now - track->start_time;
	if (age > g_config.palm_age * 0.5f) {
		track->max_velocity *= PALM_VELOCITY_DECAY;
	}

	bool is_old_enough = age >= g_config.palm_age;
	bool minimal_displacement = total_displacement < g_config.palm_disp;
	bool consistently_slow = track->max_velocity < g_config.palm_velocity * 1.2f; // Slight tolerance
	bool mostly_stationary = track->stationary_frames >= g_config.palm_stationary_threshold;
	bool limited_total_movement = track->total_distance < (g_config.palm_disp * 2.0f);

	if (is_old_enough && ((minimal_displacement && consistently_slow) || (mostly_stationary && limited_total_movement) || (consistently_slow && limited_total_movement))) {
		track->is_palm = true;
		track->palm_check_done = true;
	}

	if (age > g_config.palm_age && (total_displacement > g_config.palm_disp * 2.0f || track->max_velocity > g_config.palm_velocity * 2.0f)) {
		track->palm_check_done = true;
	}

	return track->is_palm;
}

static void reset_gesture_context()
{
	g_gesture_ctx.state = GESTURE_STATE_IDLE;
	g_gesture_ctx.last_fire_direction = 0;
	g_gesture_ctx.peak_velocity = 0.0f;
	g_gesture_ctx.active_finger_count = 0;
	g_gesture_ctx.gesture_start_time = 0;
	memset(g_gesture_ctx.velocity_history, 0, sizeof(g_gesture_ctx.velocity_history));
	g_gesture_ctx.velocity_history_idx = 0;
}

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

	if (g_config.haptic) {
		haptic_actuate(g_haptic, 3);
	}
}

static void fire_swipe_action(int direction)
{
	if (direction == g_gesture_ctx.last_fire_direction && g_gesture_ctx.state != GESTURE_STATE_IDLE)
		return;

	g_gesture_ctx.last_fire_direction = direction;
	g_gesture_ctx.state = GESTURE_STATE_COMMITTED;

	dispatch_async(g_gesture_q, ^{
		switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}

static void analyze_gesture(const touch* touches, int touch_count)
{
	if (touch_count < g_config.fingers) { // not != bc on first frame not all fingers may be detected
		if (g_gesture_ctx.state == GESTURE_STATE_ARMED || g_gesture_ctx.state == GESTURE_STATE_DETECTING) {
			g_gesture_ctx.state = GESTURE_STATE_CANCELLED;
		}

		for (int i = 0; i < touch_count && i < MAX_TOUCHES; ++i) {
			g_gesture_ctx.base_positions[i] = touches[i].x;
			g_gesture_ctx.prev_positions[i] = touches[i].x;
		}
		return;
	}

	float avg_x = 0, avg_y = 0, avg_vel_x = 0;
	for (int i = 0; i < touch_count; ++i) {
		avg_x += touches[i].x;
		avg_y += touches[i].y;
		avg_vel_x += touches[i].velocity;
	}
	avg_x /= touch_count;
	avg_y /= touch_count;
	avg_vel_x /= touch_count;

	float smoothed_vel = smooth_velocity(avg_vel_x);

	switch (g_gesture_ctx.state) {
	case GESTURE_STATE_IDLE:
	case GESTURE_STATE_CANCELLED: {
		g_gesture_ctx.gesture_start = CGPointMake(avg_x, avg_y);
		g_gesture_ctx.peak_velocity = smoothed_vel;
		g_gesture_ctx.active_finger_count = touch_count;

		for (int i = 0; i < touch_count; ++i) {
			g_gesture_ctx.start_positions[i] = touches[i].x;
			g_gesture_ctx.base_positions[i] = touches[i].x;
		}

		g_gesture_ctx.state = GESTURE_STATE_DETECTING;
		break;
	}

	case GESTURE_STATE_DETECTING: {
		float dx = avg_x - g_gesture_ctx.gesture_start.x;
		float dy = avg_y - g_gesture_ctx.gesture_start.y;

		bool is_fast = fabsf(avg_vel_x) >= g_config.velocity_pct * FAST_VEL_FACTOR; // instant vel for gating
		float required_travel = is_fast ? g_config.min_travel_fast : g_config.min_travel;

		int moved_enough = 0;
		for (int i = 0; i < touch_count; ++i)
			if (fabsf(touches[i].x - g_gesture_ctx.base_positions[i]) >= required_travel)
				moved_enough++;

		// require a maj. of fingers incase pivot finger doesnt move enough + 20% vert slack
		if (moved_enough >= touch_count - 1 && (is_fast || (fabsf(dx) >= ACTIVATE_PCT && fabsf(dx) > fabsf(dy) * 1.20f))) {
			g_gesture_ctx.state = GESTURE_STATE_ARMED;
			g_gesture_ctx.gesture_start = CGPointMake(avg_x, avg_y);
			g_gesture_ctx.peak_velocity = smoothed_vel;
		}
		break;
	}

	case GESTURE_STATE_ARMED: {
		float dx = avg_x - g_gesture_ctx.gesture_start.x;
		float dy = avg_y - g_gesture_ctx.gesture_start.y;

		if (fabsf(dy) > fabsf(dx)) { // cancel if vertical movement is dominant
			g_gesture_ctx.state = GESTURE_STATE_CANCELLED;
			break;
		}

		bool is_fast = fabsf(smoothed_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
		float required_step = is_fast ? g_config.min_step_fast : g_config.min_step;

		int inconsistent = 0;
		for (int i = 0; i < touch_count; ++i) {
			float finger_dx = touches[i].x - g_gesture_ctx.prev_positions[i];
			if (fabsf(finger_dx) < required_step || (finger_dx * dx) < 0)
				inconsistent++;
		}
		// cancel only if a majority of fingers disagree
		if (inconsistent > (touch_count / 2)) {
			g_gesture_ctx.state = GESTURE_STATE_CANCELLED;
			return;
		}

		if (fabsf(smoothed_vel) > fabsf(g_gesture_ctx.peak_velocity)) {
			g_gesture_ctx.peak_velocity = smoothed_vel;
		}

		if (fabsf(smoothed_vel) >= g_config.velocity_pct) {
			fire_swipe_action(smoothed_vel > 0 ? 1 : -1);
		} else if (fabsf(dx) >= g_config.distance_pct && fabsf(smoothed_vel) <= g_config.velocity_pct * g_config.settle_factor) {
			fire_swipe_action(dx > 0 ? 1 : -1);
		}
		break;
	}

	case GESTURE_STATE_COMMITTED: {
		bool all_ended = true;
		for (int i = 0; i < touch_count; ++i) {
			if (touches[i].phase != END_PHASE) {
				all_ended = false;
				break;
			}
		}

		if (touch_count == 0 || all_ended) {
			reset_gesture_context();
			return;
		}

		float dx = avg_x - g_gesture_ctx.gesture_start.x;
		bool direction_reversed = (dx * g_gesture_ctx.last_fire_direction) < 0;
		bool moved_enough = fabsf(dx) >= g_config.min_travel;

		if (direction_reversed && moved_enough) {
			g_gesture_ctx.state = GESTURE_STATE_DETECTING;
			g_gesture_ctx.gesture_start = CGPointMake(avg_x, avg_y);
			g_gesture_ctx.peak_velocity = smoothed_vel;
			g_gesture_ctx.last_fire_direction = 0; // Clear previous direction

			for (int i = 0; i < touch_count; ++i) {
				g_gesture_ctx.base_positions[i] = touches[i].x;
				g_gesture_ctx.start_positions[i] = touches[i].x;
			}
		}

		break;
	}
	}

	for (int i = 0; i < touch_count; ++i) {
		g_gesture_ctx.prev_positions[i] = touches[i].x;
		if (g_gesture_ctx.state == GESTURE_STATE_IDLE || g_gesture_ctx.state == GESTURE_STATE_DETECTING) {
			g_gesture_ctx.base_positions[i] = touches[i].x;
		}
	}
}

static void update_finger_tracks(NSSet<NSTouch*>* touches, CFTimeInterval now)
{
	CFIndex count = CFDictionaryGetCount(g_finger_tracks);
	if (count > 0) {
		const void* keys[count];
		const void* values[count];
		CFDictionaryGetKeysAndValues(g_finger_tracks, keys, (const void**)values);

		for (CFIndex i = 0; i < count; i++) {
			((finger_track*)values[i])->seen = false;
		}
	}

	for (NSTouch* touch in touches) {
		const void* key = (__bridge const void*)touch.identity;
		finger_track* track = (finger_track*)CFDictionaryGetValue(g_finger_tracks, key);
		CGPoint current_pos = touch.normalizedPosition;

		if (!track) {
			track = calloc(1, sizeof(finger_track));
			track->start_pos = track->last_pos = track->prev_pos = current_pos;
			track->start_time = track->last_time = track->prev_time = now;
			track->valid_for_gesture = true;
			CFDictionarySetValue(g_finger_tracks, key, track);
		}

		update_palm_detection(track, current_pos, now);

		track->prev_pos = track->last_pos;
		track->prev_time = track->last_time;
		track->last_pos = current_pos;
		track->last_time = now;
		track->seen = true;

		track->valid_for_gesture = !track->is_palm;
	}

	CFIndex dead_count = 0;
	const void* dead_keys[MAX_TOUCHES];

	count = CFDictionaryGetCount(g_finger_tracks);
	if (count > 0) {
		const void* keys[count];
		const void* values[count];
		CFDictionaryGetKeysAndValues(g_finger_tracks, keys, (const void**)values);

		for (CFIndex i = 0; i < count; i++) {
			finger_track* track = (finger_track*)values[i];
			if (!track->seen && dead_count < MAX_TOUCHES) {
				dead_keys[dead_count++] = keys[i];
			}
		}
	}

	for (CFIndex i = 0; i < dead_count; i++) {
		void* track = (void*)CFDictionaryGetValue(g_finger_tracks, dead_keys[i]);
		CFDictionaryRemoveValue(g_finger_tracks, dead_keys[i]);
		free(track);
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
		CGEventTapEnable(((struct event_tap*)ref)->handle, true);
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

	update_finger_tracks(all_touches, ev.timestamp);

	NSUInteger valid_touch_count = 0;
	for (NSTouch* touch in all_touches) {
		finger_track* track = CFDictionaryGetValue(g_finger_tracks,
			(__bridge const void*)touch.identity);
		if (track && track->valid_for_gesture) {
			valid_touch_count++;
		}
	}

	if (valid_touch_count == 0) {
		dispatch_async(g_gesture_q, ^{
			pthread_mutex_lock(&g_gesture_mutex);
			reset_gesture_context();
			pthread_mutex_unlock(&g_gesture_mutex);
		});
		return event;
	}

	touch* valid_touches = malloc(sizeof(touch) * valid_touch_count);
	NSUInteger idx = 0;

	for (NSTouch* touch in all_touches) {
		finger_track* track = CFDictionaryGetValue(g_finger_tracks,
			(__bridge const void*)touch.identity);
		if (track && track->valid_for_gesture && idx < valid_touch_count) {
			valid_touches[idx++] = [TouchConverter convert_nstouch:touch];
		}
	}

	dispatch_async(g_gesture_q, ^{
		pthread_mutex_lock(&g_gesture_mutex);
		analyze_gesture(valid_touches, (int)valid_touch_count);
		pthread_mutex_unlock(&g_gesture_mutex);
		free(valid_touches);
	});

	return event;
}

static void acquire_lockfile(void)
{
	char* user = getenv("USER");
	if (!user) {
		printf("Error: User variable not set.\n");
		exit(1);
	}

	char buffer[256];
	snprintf(buffer, sizeof(buffer), "/tmp/aerospace-swipe-%s.lock", user);

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
	[[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:bundlePath]
										  configuration:[NSWorkspaceOpenConfiguration configuration]
									  completionHandler:nil];
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

		[[NSProcessInfo processInfo] disableSuddenTermination];

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

		g_finger_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		dispatch_queue_attr_t qos_attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
		g_gesture_q = dispatch_queue_create("aerospace-swipe.serial", qos_attr);

		reset_gesture_context();

		event_tap_begin(&g_event_tap, key_handler);

		return NSApplicationMain(argc, argv);
	}
}

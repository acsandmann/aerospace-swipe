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

#define ACTIVATE_PCT 0.05f // min 5 % travel before tracking
#define END_PHASE 8 // NSTouchPhaseEnded

#define MIN_STEP 0.005f // 0.5 % pad width / frame
#define MIN_FINGER_TRAVEL 0.015f // 1.5 % pad width to arm

#define MAX_SPREAD_X 0.40f // palm X width threshold
#define MAX_SPREAD_Y 0.15f // palm Y height threshold

#define FAST_VEL_FACTOR 0.80f // ≥80 % of commit velocity
#define MIN_STEP_FAST 0.0f
#define MIN_TRAVEL_FAST 0.006f

#define MAX_TOUCHES 16

static void gestureCallback(touch* c, int n)
{
	pthread_mutex_lock(&g_gesture_mutex);

	enum { GS_IDLE,
		GS_ARMED,
		GS_COMMITTED } static state
		= GS_IDLE;

	static float startX = 0, startY = 0;
	static float peakVelX = 0;
	static int dir = 0;
	static int lastFireDir = 0;

	static float prev_x[MAX_TOUCHES] = { 0 };
	static float base_x[MAX_TOUCHES] = { 0 };

	void (^reset)(void) = ^{
		state = GS_IDLE;
		lastFireDir = 0;
	};

	void (^fire)(int) = ^(int d) {
		// block duplicates in the same direction without lifting
		if (d == lastFireDir)
			return;

		lastFireDir = d;
		state = GS_COMMITTED;

		const char* ws = (d > 0) ? g_config.swipe_right
								 : g_config.swipe_left;
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
			^{ switch_workspace(ws); });
	};

	if (state == GS_COMMITTED) {
		bool allEnded = true;
		for (int i = 0; i < n; ++i)
			if (c[i].phase != END_PHASE) {
				allEnded = false;
				break;
			}

		if (n == 0 || allEnded) {
			reset();
			pthread_mutex_unlock(&g_gesture_mutex);
			return;
		}

		float sumX = 0, sumY = 0, sumVX = 0;
		for (int i = 0; i < n; ++i) {
			sumX += c[i].x;
			sumY += c[i].y;
			sumVX += c[i].velocity;
		}
		float ax = sumX / n;
		float ay = sumY / n;
		float vx = sumVX / n;
		float dx = ax - startX;

		if ((dx * lastFireDir) < 0 && fabsf(dx) >= MIN_FINGER_TRAVEL) {
			state = GS_ARMED;
			startX = ax;
			startY = ay;
			peakVelX = vx;
			dir = (vx >= 0) ? +1 : -1;
			for (int i = 0; i < n; ++i)
				base_x[i] = c[i].x;
		} else {
			pthread_mutex_unlock(&g_gesture_mutex);
			return;
		}
	}

	if (n != g_config.fingers) {
		if (state == GS_ARMED)
			state = GS_IDLE;

		for (int i = 0; i < n; ++i) {
			base_x[i] = c[i].x;
			prev_x[i] = c[i].x;
		}

		pthread_mutex_unlock(&g_gesture_mutex);
		return;
	}

	float sumX = 0, sumY = 0, sumVX = 0;
	float minX = 1, maxX = 0, minY = 1, maxY = 0;
	for (int i = 0; i < n; ++i) {
		sumX += c[i].x;
		sumY += c[i].y;
		sumVX += c[i].velocity;
		if (c[i].x < minX)
			minX = c[i].x;
		if (c[i].x > maxX)
			maxX = c[i].x;
		if (c[i].y < minY)
			minY = c[i].y;
		if (c[i].y > maxY)
			maxY = c[i].y;
	}
	float ax = sumX / n, ay = sumY / n, vx = sumVX / n;

	if ((maxX - minX) > MAX_SPREAD_X && (maxY - minY) > MAX_SPREAD_Y) {
		reset();
		goto update;
	}

	if (state == GS_IDLE) {
		bool fast = fabsf(vx) >= g_config.velocity_pct * FAST_VEL_FACTOR;
		float need = fast ? MIN_TRAVEL_FAST : MIN_FINGER_TRAVEL;
		bool moved = true;
		for (int i = 0; i < n; ++i)
			if (fabsf(c[i].x - base_x[i]) < need) {
				moved = false;
				break;
			}

		float dx = ax - startX;
		float dy = ay - startY;
		bool horizOK = fast || (fabsf(dx) >= ACTIVATE_PCT && fabsf(dx) > fabsf(dy));

		if (moved && horizOK) {
			state = GS_ARMED;
			startX = ax;
			startY = ay;
			peakVelX = vx;
			dir = (vx >= 0) ? +1 : -1;
		}
		goto update;
	}

	float dx = ax - startX;
	float dy = ay - startY;
	if (fabsf(dy) > fabsf(dx)) {
		reset();
		goto update;
	}

	bool fast = fabsf(vx) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? MIN_STEP_FAST : MIN_STEP;

	bool allOK = true;
	for (int i = 0; i < n; ++i) {
		float ddx = c[i].x - prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			allOK = false;
			break;
		}
	}
	if (!allOK) {
		reset();
		goto update;
	}

	if (fabsf(vx) > fabsf(peakVelX)) {
		peakVelX = vx;
		dir = (vx >= 0) ? +1 : -1;
	}

	if (fabsf(vx) >= g_config.velocity_pct)
		fire((vx > 0) ? +1 : -1);
	else if (fabsf(dx) >= g_config.distance_pct && fabsf(vx) <= g_config.velocity_pct * g_config.settle_factor)
		fire((dx > 0) ? +1 : -1);

update:
	for (int i = 0; i < n; ++i) {
		prev_x[i] = c[i].x;
		if (state == GS_IDLE)
			base_x[i] = c[i].x;
	}
	pthread_mutex_unlock(&g_gesture_mutex);
}

static CGEventRef key_handler(CGEventTapProxy proxy,
	CGEventType type,
	CGEventRef event,
	void* reference)
{
	if (!AXIsProcessTrusted()) {
		NSLog(@"Accessibility permission lost. Disabling event tap to allow system events.");
		event_tap_end((struct event_tap*)reference);
		return event;
	}

	switch (type) {
	case kCGEventTapDisabledByTimeout:
		NSLog(@"Timeout.\n");
	case kCGEventTapDisabledByUserInput:
		NSLog(@"Re‐enabling event tap.\n");
		CGEventTapEnable(((struct event_tap*)reference)->handle, true);
		break;
	case NSEventTypeGesture: {
		NSEvent* nsEvent = [NSEvent eventWithCGEvent:event];
		NSSet<NSTouch*>* touches = nsEvent.allTouches;
		NSUInteger count = touches.count;

		if (count == 0)
			return event;

		touch* nativeTouches = malloc(sizeof(touch) * count);
		if (nativeTouches == NULL)
			return event;

		NSUInteger i = 0;
		for (NSTouch* aTouch in touches)
			nativeTouches[i++] = [TouchConverter convert_nstouch:aTouch];

		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			gestureCallback(nativeTouches, count);
			free(nativeTouches);
		});

		return event;
	}
	}

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

		event_tap_begin(&g_event_tap, key_handler);

		return NSApplicationMain(argc, argv);
	}
}

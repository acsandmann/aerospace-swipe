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

static void gestureCallback(touch* contacts, int numContacts)
{
	pthread_mutex_lock(&g_gesture_mutex);
	static bool swiping = false;
	static float startAvgX = 0.0f;
	static float startAvgY = 0.0f;
	static double lastSwipeTime = 0.0;
	static int consecutiveRightFrames = 0;
	static int consecutiveLeftFrames = 0;

	if (numContacts != g_config.fingers || (contacts[0].timestamp - lastSwipeTime) < g_config.swipe_cooldown) {
		swiping = false;
		consecutiveRightFrames = 0;
		consecutiveLeftFrames = 0;
		pthread_mutex_unlock(&g_gesture_mutex);
		return;
	}

	float sumX = 0.0f;
	float sumVelX = 0.0f;
	float sumY = 0.0f;

	for (int i = 0; i < numContacts; ++i) {
		sumX += contacts[i].x;
		sumVelX += contacts[i].velocity;
		sumY += contacts[i].y;
	}

	const float avgX = sumX / numContacts;
	const float avgVelX = sumVelX / numContacts;
	const float avgY = sumY / numContacts;

	if (!swiping) {
		swiping = true;
		startAvgX = avgX;
		startAvgY = avgY;
		consecutiveRightFrames = 0;
		consecutiveLeftFrames = 0;
	} else {
		const float deltaX = avgX - startAvgX;
		const float deltaY = avgY - startAvgY;

		if (fabs(deltaY) > fabs(deltaX)) {
			pthread_mutex_unlock(&g_gesture_mutex);
			return;
		}

		bool triggered = false;
		if (avgVelX > g_config.velocity_swipe_threshold) {
			consecutiveRightFrames++;
			consecutiveLeftFrames = 0;
			if (consecutiveRightFrames >= g_config.velocity_frames_threshold) {
				NSLog(@"Right swipe (by velocity) detected.\n");
				switch_workspace(g_config.swipe_right);
				triggered = true;
				consecutiveRightFrames = 0;
			}
		} else if (avgVelX < -g_config.velocity_swipe_threshold) {
			consecutiveLeftFrames++;
			consecutiveRightFrames = 0;
			if (consecutiveLeftFrames >= g_config.velocity_frames_threshold) {
				NSLog(@"Left swipe (by velocity) detected.\n");
				switch_workspace(g_config.swipe_left);
				triggered = true;
				consecutiveLeftFrames = 0;
			}
		} else if (deltaX > g_config.swipe_threshold) {
			NSLog(@"Right swipe (by position) detected.\n");
			switch_workspace(g_config.swipe_right);
			triggered = true;
		} else if (deltaX < -g_config.swipe_threshold) {
			NSLog(@"Left swipe (by position) detected.\n");
			switch_workspace(g_config.swipe_left);
			triggered = true;
		}

		if (triggered) {
			lastSwipeTime = contacts[0].timestamp;
			swiping = false;
		}
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

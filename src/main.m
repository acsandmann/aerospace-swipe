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

#define ACTIVATE_PCT 0.05f
#define END_PHASE 8 // NSTouchPhaseEnded
#define MIN_STEP 0.005f
#define MIN_FINGER_TRAVEL 0.015f
#define FAST_VEL_FACTOR 0.80f
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
	static float startX, startY, peakVelX;
	static int dir, lastFireDir;
	static float prev_x[MAX_TOUCHES], base_x[MAX_TOUCHES];

	void (^reset)(void) = ^{ state = GS_IDLE; lastFireDir = 0; };
	void (^fire)(int) = ^(int d) {
		if (d == lastFireDir)
			return;
		lastFireDir = d;
		state = GS_COMMITTED;
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			switch_workspace(d > 0 ? g_config.swipe_right : g_config.swipe_left);
		});
	};

	if (state == GS_COMMITTED) {
		bool ended = true;
		for (int i = 0; i < n && ended; ++i)
			ended &= (c[i].phase == END_PHASE);
		if (!n || ended) {
			reset();
			goto unlock;
		}

		float ax = 0, ay = 0, vx = 0;
		for (int i = 0; i < n; ++i) {
			ax += c[i].x;
			ay += c[i].y;
			vx += c[i].velocity;
		}
		ax /= n;
		ay /= n;
		vx /= n;

		float dx = ax - startX;
		if ((dx * lastFireDir) < 0 && fabsf(dx) >= MIN_FINGER_TRAVEL) {
			state = GS_ARMED;
			startX = ax;
			startY = ay;
			peakVelX = vx;
			dir = (vx >= 0) ? 1 : -1;
			for (int i = 0; i < n; ++i)
				base_x[i] = c[i].x;
		}
		goto unlock;
	}

	if (n != g_config.fingers) {
		if (state == GS_ARMED)
			state = GS_IDLE;
		for (int i = 0; i < n; ++i)
			prev_x[i] = base_x[i] = c[i].x;
		goto unlock;
	}

	float ax = 0, ay = 0, vx = 0, minX = 1, maxX = 0, minY = 1, maxY = 0;
	for (int i = 0; i < n; ++i) {
		ax += c[i].x;
		ay += c[i].y;
		vx += c[i].velocity;
		if (c[i].x < minX)
			minX = c[i].x;
		if (c[i].x > maxX)
			maxX = c[i].x;
		if (c[i].y < minY)
			minY = c[i].y;
		if (c[i].y > maxY)
			maxY = c[i].y;
	}
	ax /= n;
	ay /= n;
	vx /= n;

	if (state == GS_IDLE) {
		bool fast = fabsf(vx) >= g_config.velocity_pct * FAST_VEL_FACTOR;
		float need = fast ? MIN_TRAVEL_FAST : MIN_FINGER_TRAVEL;
		bool moved = true;
		for (int i = 0; i < n && moved; ++i)
			moved &= fabsf(c[i].x - base_x[i]) >= need;

		float dx = ax - startX, dy = ay - startY;
		if (moved && (fast || (fabsf(dx) >= ACTIVATE_PCT && fabsf(dx) > fabsf(dy)))) {
			state = GS_ARMED;
			startX = ax;
			startY = ay;
			peakVelX = vx;
			dir = (vx >= 0) ? 1 : -1;
		}
		goto update;
	}

	float dx = ax - startX, dy = ay - startY;
	if (fabsf(dy) > fabsf(dx)) {
		reset();
		goto update;
	}

	bool fast = fabsf(vx) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? MIN_STEP_FAST : MIN_STEP;
	for (int i = 0; i < n; ++i) {
		float ddx = c[i].x - prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			reset();
			goto update;
		}
	}
	if (fabsf(vx) > fabsf(peakVelX)) {
		peakVelX = vx;
		dir = (vx >= 0) ? 1 : -1;
	}

	if (fabsf(vx) >= g_config.velocity_pct)
		fire(vx > 0 ? 1 : -1);
	else if (fabsf(dx) >= g_config.distance_pct && fabsf(vx) <= g_config.velocity_pct * g_config.settle_factor)
		fire(dx > 0 ? 1 : -1);

update:
	for (int i = 0; i < n; ++i) {
		prev_x[i] = c[i].x;
		if (state == GS_IDLE)
			base_x[i] = c[i].x;
	}
unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

typedef struct {
	CGPoint start, last;
	CFTimeInterval tStart, tLast;
	CGFloat travel;
	bool isPalm, seen;
} FingerTrack;

static CFMutableDictionaryRef gTracks;
static const CGFloat PALM_STEP   = 0.05;   // 5 % pad / frame
static const CGFloat PALM_DISP   = 0.025;    // 2.5 % pad from origin
static const CFTimeInterval PALM_AGE = 0.06; // 60 ms before we judge
static const CGFloat PALM_VELOCITY = 0.1;    // 10% of pad dimension per second

static void update_tracks(NSSet<NSTouch*> *touches, CFTimeInterval now)
{
    for (id k in (__bridge NSDictionary*)gTracks)
        ((FingerTrack *)CFDictionaryGetValue(gTracks, (__bridge const void*)k))->seen = false;

    for (NSTouch *t in touches) {
        const void *key = (__bridge const void*)t.identity;
        FingerTrack *trk = (FingerTrack *)CFDictionaryGetValue(gTracks, key);
        CGPoint p = t.normalizedPosition;

        if (!trk) {
            trk = calloc(1, sizeof *trk);
            trk->start = trk->last = p;
            trk->tStart = trk->tLast = now;
            CFDictionarySetValue(gTracks, key, trk);
        }

        CFTimeInterval dt = now - trk->tLast;

        CGFloat step = hypot(p.x - trk->last.x, p.y - trk->last.y);
        CGFloat vel = (dt > 0) ? (step / dt) : 0.0f;

        CGFloat disp = hypot(p.x - trk->start.x, p.y - trk->start.y);

        trk->last  = p;
        trk->tLast = now;

        if (!trk->isPalm) { // set until liftoff
            bool agedEnough  = (now - trk->tStart) > PALM_AGE;
            bool trivialDisp = disp < PALM_DISP;
            bool slowEnough  = vel < PALM_VELOCITY;

            // age + displacement + velocity
            if (agedEnough && trivialDisp && slowEnough)
                trk->isPalm = true;
        }
        trk->seen = true;
    }

    NSMutableArray *dead = [NSMutableArray array];
    for (id k in (__bridge NSDictionary*)gTracks)
        if (!((FingerTrack*)CFDictionaryGetValue(gTracks, (__bridge const void*)k))->seen)
            [dead addObject:k];

    for (id k in dead) {
        free(CFDictionaryGetValue(gTracks, (__bridge const void*)k));
        CFDictionaryRemoveValue(gTracks, (__bridge const void*)k);
    }
}

static CGEventRef key_handler(CGEventTapProxy proxy, CGEventType type,
	CGEventRef event, void* ref)
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

	if (type != NSEventTypeGesture)
		return event;

	NSEvent* ev = [NSEvent eventWithCGEvent:event];
	NSSet<NSTouch*>* touches = ev.allTouches;
	if (!touches.count)
		return event;

	update_tracks(touches, ev.timestamp);

	NSUInteger live = 0;
	for (NSTouch* t in touches) {
		FingerTrack* trk = CFDictionaryGetValue(gTracks, (__bridge const void*)t.identity);
		if (trk && !trk->isPalm)
			++live;
	}
	if (!live)
		return event;

	touch* buf = malloc(sizeof(touch) * live);
	NSUInteger i = 0;
	for (NSTouch* t in touches) {
		FingerTrack* trk = CFDictionaryGetValue(gTracks, (__bridge const void*)t.identity);
		if (trk && !trk->isPalm)
			buf[i++] = [TouchConverter convert_nstouch:t];
	}
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(buf, (int)live);
		free(buf);
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

		gTracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks, // retain keys
			NULL); // leave values alone

		event_tap_begin(&g_event_tap, key_handler);

		return NSApplicationMain(argc, argv);
	}
}

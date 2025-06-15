#pragma once
#include <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <stdbool.h>
#include <stdint.h>

#define ACTIVATE_PCT 0.05f
#define END_PHASE 8 // NSTouchPhaseEnded
#define FAST_VEL_FACTOR 0.80f
#define MAX_TOUCHES 16

extern const char* get_name_for_pid(uint64_t pid);
extern char* string_copy(char* s);

struct event_tap {
	CFMachPortRef handle;
	CFRunLoopSourceRef runloop_source;
	CGEventMask mask;
};

typedef struct {
	double x;
	double y;
	int phase;
	double timestamp;
	double velocity;
	bool is_palm;
} touch;

typedef struct {
	double x;
	double y;
	double timestamp;
} touch_state;

// Gesture state enumeration
typedef enum {
	GS_IDLE,
	GS_ARMED,
	GS_COMMITTED
} gesture_state;

// Gesture context structure
typedef struct {
	gesture_state state;
	float start_x, start_y, peak_velx;
	int dir, last_fire_dir;
	float prev_x[MAX_TOUCHES], base_x[MAX_TOUCHES];
} gesture_ctx;

// Palm rejection tracking structure
typedef struct {
	CGPoint start, last;
	CFTimeInterval t_start, t_last;
	CGFloat travel;
	bool is_palm, seen;
} finger_track;

@interface TouchConverter : NSObject
+ (touch)convert_nstouch:(id)nsTouch;
@end

struct event_tap g_event_tap;
static CFMutableDictionaryRef touchStates;

bool event_tap_enabled(struct event_tap* event_tap);
bool event_tap_begin(struct event_tap* event_tap, CGEventRef (*reference)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userdata));
void event_tap_end(struct event_tap* event_tap);

#pragma once
#include <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <stdbool.h>
#include <stdint.h>

extern const char* get_name_for_pid(uint64_t pid);
extern char* string_copy(char* s);

#define MAX_TOUCHES 16
#define ACTIVATE_PCT 0.05f
#define FAST_VEL_FACTOR 0.80f
#define END_PHASE 8 // NSTouchPhase

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
} touch;

typedef struct {
	double x;
	double y;
	double timestamp;
} touch_state;

typedef struct {
	CGPoint start_pos;
	CGPoint last_pos;
	CGPoint prev_pos;
	CFTimeInterval start_time;
	CFTimeInterval last_time;
	CFTimeInterval prev_time;

	bool is_palm;
	bool palm_check_done;
	float max_velocity;
	float total_distance;
	int stationary_frames;

	bool seen;
	bool valid_for_gesture;
} finger_track;

typedef enum {
	GESTURE_STATE_IDLE = 0,
	GESTURE_STATE_DETECTING,
	GESTURE_STATE_ARMED,
	GESTURE_STATE_COMMITTED,
	GESTURE_STATE_CANCELLED
} gesture_state;

typedef struct {
	gesture_state state;
	int last_fire_direction;

	float start_positions[MAX_TOUCHES];
	float base_positions[MAX_TOUCHES];
	float prev_positions[MAX_TOUCHES];

	CGPoint gesture_start;
	float peak_velocity;
	int active_finger_count;
	CFTimeInterval gesture_start_time;

	float velocity_history[3];
	int velocity_history_idx;

} gesture_context;

@interface TouchConverter : NSObject
+ (touch)convert_nstouch:(id)nsTouch;
@end

struct event_tap g_event_tap;
static CFMutableDictionaryRef touchStates;

bool event_tap_enabled(struct event_tap* event_tap);
bool event_tap_begin(struct event_tap* event_tap, CGEventRef (*reference)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userdata));
void event_tap_end(struct event_tap* event_tap);

#pragma once
#include <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <stdbool.h>
#include <stdint.h>

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

@interface TouchConverter : NSObject
+ (touch)convert_nstouch:(id)nsTouch;
@end

struct event_tap g_event_tap;
static CFMutableDictionaryRef touchStates;

bool event_tap_enabled(struct event_tap* event_tap);
bool event_tap_begin(struct event_tap* event_tap, CGEventRef (*reference)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userdata));
void event_tap_end(struct event_tap* event_tap);

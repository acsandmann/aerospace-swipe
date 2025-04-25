#import "event_tap.h"
#import <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

@implementation TouchConverter

+ (touch)convert_nstouch:(id)nsTouch
{
	NSTouch* touchObj = (NSTouch*)nsTouch;
	touch nt;

	CGPoint pos = [touchObj normalizedPosition];
	nt.x = pos.x;
	nt.y = pos.y;

	nt.phase = (int)[touchObj phase];
	nt.timestamp = [[touchObj valueForKey:@"timestamp"] doubleValue];

	id touchIdentity = [touchObj identity];

	if (!touchStates) {
		touchStates = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);
	}

	double velocity_x = 0.0;
	touch_state* state = (touch_state*)CFDictionaryGetValue(touchStates, (__bridge const void*)(touchIdentity));
	if (state) {
		double dt = nt.timestamp - state->timestamp;
		if (dt > 0)
			velocity_x = (nt.x - state->x) / dt;
		state->x = nt.x;
		state->y = nt.y;
		state->timestamp = nt.timestamp;
	} else {
		state = malloc(sizeof(touch_state));
		if (state) {
			state->x = nt.x;
			state->y = nt.y;
			state->timestamp = nt.timestamp;
			CFDictionarySetValue(touchStates, (__bridge const void*)(touchIdentity), state);
		}
	}
	nt.velocity = velocity_x;

	if (nt.phase == 8) {
		CFDictionaryRemoveValue(touchStates, (__bridge const void*)(touchIdentity));
		if (state)
			free(state);
	}

	return nt;
}

@end

bool event_tap_enabled(struct event_tap* event_tap)
{
	bool result = (event_tap->handle && CGEventTapIsEnabled(event_tap->handle));
	return result;
}

bool event_tap_begin(struct event_tap* event_tap, CGEventRef (*reference)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userdata))
{
	event_tap->mask = 1 << NSEventTypeGesture;
	event_tap->handle = CGEventTapCreate(
		kCGHIDEventTap,
		kCGHeadInsertEventTap,
		kCGEventTapOptionListenOnly,
		event_tap->mask,
		*reference,
		event_tap);

	bool result = event_tap_enabled(event_tap);
	if (result) {
		event_tap->runloop_source = CFMachPortCreateRunLoopSource(
			kCFAllocatorDefault,
			event_tap->handle,
			0);
		CFRunLoopAddSource(CFRunLoopGetMain(),
			event_tap->runloop_source,
			kCFRunLoopDefaultMode);
	}

	return result;
}

void event_tap_end(struct event_tap* event_tap)
{
	if (event_tap_enabled(event_tap)) {
		CGEventTapEnable(event_tap->handle, false);
		CFMachPortInvalidate(event_tap->handle);
		CFRunLoopRemoveSource(CFRunLoopGetMain(),
			event_tap->runloop_source,
			kCFRunLoopCommonModes);
		CFRelease(event_tap->runloop_source);
		CFRelease(event_tap->handle);
		event_tap->handle = NULL;
	}
}

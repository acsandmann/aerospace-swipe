#include "haptic.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_error.h>
#include <stdio.h>

#define CF_RELEASE(obj)                                                                                                \
	do {                                                                                                               \
		if ((obj) != NULL) {                                                                                           \
			CFRelease(obj);                                                                                            \
			(obj) = NULL;                                                                                              \
		}                                                                                                              \
	} while (0)

static const CFStringRef kMTRegistryKeyID = CFSTR("Multitouch ID");

CFTypeRef haptic_open(uint64_t deviceID)
{
	CFTypeRef act = MTActuatorCreateFromDeviceID(deviceID);
	if (!act) {
		fprintf(stderr, "No actuator for device %llu\n", (unsigned long long)deviceID);
		return NULL;
	}
	IOReturn kr = MTActuatorOpen(act);
	if (kr != kIOReturnSuccess) {
		fprintf(stderr, "MTActuatorOpen: 0x%04x (%s)\n", kr, mach_error_string(kr));
		CF_RELEASE(act);
	}
	return act;
}

static void iterate_multitouch(io_iterator_t iter, void (^callback)(uint64_t devID))
{
	io_object_t dev;
	while ((dev = IOIteratorNext(iter))) {

		CFNumberRef idRef = (CFNumberRef)IORegistryEntryCreateCFProperty(dev, kMTRegistryKeyID, kCFAllocatorDefault, 0);

		if (idRef && CFGetTypeID(idRef) == CFNumberGetTypeID()) {
			uint64_t id = 0;
			CFNumberGetValue(idRef, kCFNumberSInt64Type, &id);
			callback(id);
		}

		CF_RELEASE(idRef);
		IOObjectRelease(dev);
	}
}

static io_iterator_t matching_iterator(void)
{
	io_iterator_t it = MACH_PORT_NULL;
	kern_return_t kr
		= IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &it);
	if (kr != KERN_SUCCESS) return MACH_PORT_NULL;

	return it;
}

CFTypeRef haptic_open_default(void)
{
	io_iterator_t it = matching_iterator();
	if (it == MACH_PORT_NULL) return NULL;

	__block CFTypeRef chosen = NULL;

	iterate_multitouch(it, ^(uint64_t id) {
		if (!chosen) chosen = haptic_open(id);
	});

	IOObjectRelease(it);
	return chosen;
}

CFMutableArrayRef haptic_open_all(void)
{
	CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

	io_iterator_t it = matching_iterator();
	if (it == MACH_PORT_NULL) return arr;

	iterate_multitouch(it, ^(uint64_t id) {
		CFTypeRef act = haptic_open(id);
		if (act) CFArrayAppendValue(arr, act);
	});

	IOObjectRelease(it);
	return arr;
}

static inline IOReturn _actuate(CFTypeRef act, int32_t pattern)
{
	if (!act || !MTActuatorIsOpen(act)) return kIOReturnNotOpen;

	return MTActuatorActuate(act, pattern, 0, 0.0f, 0.0f);
}

bool haptic_actuate(CFTypeRef act, int32_t pattern)
{
	IOReturn kr = _actuate(act, pattern);
	if (kr != kIOReturnSuccess) {
		fprintf(stderr, "haptic_actuate: 0x%04x (%s)\n", kr, mach_error_string(kr));
		return false;
	}
	return true;
}

void haptic_actuate_all(CFArrayRef arr, int32_t pattern)
{
	if (!arr) return;
	CFIndex n = CFArrayGetCount(arr);
	for (CFIndex i = 0; i < n; ++i) _actuate(CFArrayGetValueAtIndex(arr, i), pattern);
}

void haptic_close(CFTypeRef act)
{
	if (act && MTActuatorIsOpen(act)) MTActuatorClose(act);

	CF_RELEASE(act);
}

void haptic_close_all(CFArrayRef arr)
{
	if (!arr) return;
	CFIndex n = CFArrayGetCount(arr);
	for (CFIndex i = 0; i < n; ++i) haptic_close((CFTypeRef)CFArrayGetValueAtIndex(arr, i));

	CFRelease(arr);
}

#include "haptic.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_error.h>
#include <stdio.h>

static void release(CFTypeRef* typeRefRef)
{
	if (*typeRefRef) {
		CFRelease(*typeRefRef);
		*typeRefRef = NULL;
	}
}

CFTypeRef haptic_open(UInt64 deviceID)
{
	CFTypeRef actuator = MTActuatorCreateFromDeviceID(deviceID);
	if (!actuator) {
		fprintf(stderr, "Failed to create actuator.\n");
		return NULL;
	}

	IOReturn err = MTActuatorOpen(actuator);
	if (err != kIOReturnSuccess) {
		fprintf(stderr, "Failed to open actuator: 0x%04x\n", err);
		CFRelease(actuator);
		return NULL;
	}

	return actuator;
}

CFTypeRef haptic_open_default(void)
{
	CFMutableDictionaryRef matchDict = IOServiceMatching("AppleMultitouchDevice");
	if (!matchDict) {
		fprintf(stderr, "Failed to create match dictionary\n");
		return NULL;
	}

	io_iterator_t iter;
	kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iter);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "Failed to get matching services: 0x%x\n", kr);
		return NULL;
	}

	io_object_t device;
	CFTypeRef actuator = NULL;

	while ((device = IOIteratorNext(iter))) {
		CFTypeRef idRef = IORegistryEntryCreateCFProperty(
			device, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
		if (idRef && CFGetTypeID(idRef) == CFNumberGetTypeID()) {
			UInt64 deviceID;
			CFNumberGetValue((CFNumberRef)idRef, kCFNumberSInt64Type, &deviceID);
			CFRelease(idRef);
			IOObjectRelease(device);

			actuator = haptic_open(deviceID);
			break;
		}
		if (idRef)
			CFRelease(idRef);
		IOObjectRelease(device);
	}

	IOObjectRelease(iter);
	return actuator;
}

IOReturn _haptic_actuate(CFTypeRef actuatorRef, SInt32 actuationID)
{
	if (!actuatorRef || !MTActuatorIsOpen(actuatorRef)) {
		fprintf(stderr, "Failed to return haptic feedback, actuator not open");
		return kIOReturnNotOpen;
	}

	return MTActuatorActuate(actuatorRef, actuationID, 0, 0.0f, 0.0f);
}

bool haptic_actuate(CFTypeRef actuatorRef, SInt32 actuationID)
{
	IOReturn kr = _haptic_actuate(actuatorRef, actuationID);
	if (kr != kIOReturnSuccess) {
		fprintf(stderr,
			"haptic_actuate failed: %s (0x%x)\n",
			mach_error_string(kr),
			(unsigned)kr);

		return false;
	} else
		return true;
}

void haptic_close(CFTypeRef actuatorRef)
{
	if (actuatorRef && MTActuatorIsOpen(actuatorRef)) {
		MTActuatorClose(actuatorRef);
	}
	release(&actuatorRef);
}

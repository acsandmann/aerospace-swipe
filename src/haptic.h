#define HAPTIC_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <stdbool.h>

extern CFTypeRef MTActuatorCreateFromDeviceID(UInt64 deviceID);
extern IOReturn MTActuatorOpen(CFTypeRef actuatorRef);
extern IOReturn MTActuatorClose(CFTypeRef actuatorRef);
extern IOReturn MTActuatorActuate(CFTypeRef actuatorRef, SInt32 actuationID,
	UInt32 unknown1, Float32 unknown2,
	Float32 unknown3);
extern bool MTActuatorIsOpen(CFTypeRef actuatorRef);

CFTypeRef haptic_open(UInt64 deviceID);

CFTypeRef haptic_open_default(void);

bool haptic_actuate(CFTypeRef actuatorRef, SInt32 actuationID);

void haptic_close(CFTypeRef actuatorRef);

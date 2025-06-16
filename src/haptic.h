#define HAPTIC_H

#include <IOKit/IOKitLib.h>

extern CFTypeRef MTActuatorCreateFromDeviceID(UInt64 deviceID);
extern IOReturn MTActuatorOpen(CFTypeRef actuatorRef);
extern IOReturn MTActuatorClose(CFTypeRef actuatorRef);
extern IOReturn MTActuatorActuate(
	CFTypeRef actuatorRef, SInt32 actuationID, UInt32 unknown1, Float32 unknown2, Float32 unknown3);
extern bool MTActuatorIsOpen(CFTypeRef actuatorRef);

CFTypeRef haptic_open(uint64_t deviceID);
CFTypeRef haptic_open_default(void);
CFMutableArrayRef haptic_open_all(void);

bool haptic_actuate(CFTypeRef actuator, int32_t pattern);
void haptic_actuate_all(CFArrayRef actuators, int32_t pattern);

void haptic_close(CFTypeRef actuator);
void haptic_close_all(CFArrayRef actuators);

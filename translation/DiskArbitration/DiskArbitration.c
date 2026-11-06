#include <CoreFoundation/CoreFoundation.h>
#include "AKSupport.h"

// Disk Arbitration for an app on the iPad: there is one disk, local and fixed,
// holding the app's container. WoW asks whether its folder is on a network
// volume; nil answers from stubs made its first frame read address 0x71.
// A session and a disk are plain CF objects the guest can retain and release.
typedef CFTypeRef DASessionRef;
typedef CFDictionaryRef DADiskRef;
typedef unsigned int io_service_t;

#define DA_KEY(name, value) const CFStringRef name = CFSTR(value)
DA_KEY(kDADiskDescriptionVolumeNetworkKey, "DAVolumeNetwork");
DA_KEY(kDADiskDescriptionVolumePathKey, "DAVolumePath");
DA_KEY(kDADiskDescriptionVolumeKindKey, "DAVolumeKind");
DA_KEY(kDADiskDescriptionVolumeNameKey, "DAVolumeName");
DA_KEY(kDADiskDescriptionVolumeMountableKey, "DAVolumeMountable");
DA_KEY(kDADiskDescriptionMediaRemovableKey, "DAMediaRemovable");
DA_KEY(kDADiskDescriptionMediaEjectableKey, "DAMediaEjectable");
DA_KEY(kDADiskDescriptionDeviceInternalKey, "DADeviceInternal");

DASessionRef DASessionCreate(CFAllocatorRef allocator) {
    AKLogC("DiskArbitration: session for the app's one local disk");
    return CFStringCreateWithCString(allocator, "Tolkara disk arbitration session", kCFStringEncodingUTF8);
}

DADiskRef DADiskCreateFromVolumePath(CFAllocatorRef allocator, DASessionRef session, CFURLRef path) {
    if (!session || !path) return NULL;
    const void *keys[] = {
        kDADiskDescriptionVolumeNetworkKey, kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeKindKey,
        kDADiskDescriptionVolumeNameKey, kDADiskDescriptionVolumeMountableKey, kDADiskDescriptionMediaRemovableKey,
        kDADiskDescriptionMediaEjectableKey, kDADiskDescriptionDeviceInternalKey,
    };
    const void *values[] = {
        kCFBooleanFalse, path, CFSTR("apfs"), CFSTR("Data"), kCFBooleanTrue, kCFBooleanFalse, kCFBooleanFalse, kCFBooleanTrue,
    };
    AKLogC("DiskArbitration: volume path is on a local, internal disk");
    return CFDictionaryCreate(allocator, keys, values, sizeof keys / sizeof *keys,
                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

CFDictionaryRef DADiskCopyDescription(DADiskRef disk) {
    return disk ? CFDictionaryCreateCopy(kCFAllocatorDefault, disk) : NULL;
}

// No I/O Kit media object is exposed on iPadOS.
io_service_t DADiskCopyIOMedia(DADiskRef disk) { (void)disk; return 0; }

// Per-mouse pointer acceleration on/off (what LinearMouse's "Disable pointer acceleration" does).
// Works on the macOS HID event system service for the mouse, not on the mouse itself, so it
// needs the app running and is re-applied when the mouse reconnects.
// Approach mirrors LinearMouse (MIT): HIDUseLinearScalingMouseAcceleration = 1 where the
// service supports it, otherwise the acceleration value set to -1 (IOFixed -65536).
#include "razer_transport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <dlfcn.h>

#define RAZER_VID 0x1532
#define LINEAR_KEY CFSTR("HIDUseLinearScalingMouseAcceleration")
#define ACCEL_TYPE_KEY CFSTR("HIDPointerAccelerationType")
#define MOUSE_ACCEL_KEY CFSTR("HIDMouseAcceleration")

static IOHIDEventSystemClientRef client(void) {
    static IOHIDEventSystemClientRef c = NULL;
    if (c) return c;
    // The full client (same one LinearMouse uses) can set service properties; the public
    // simple client is the fallback.
    typedef IOHIDEventSystemClientRef (*CreateFn)(CFAllocatorRef);
    CreateFn full = (CreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    if (full) c = full(kCFAllocatorDefault);
    if (!c) c = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    return c;
}

static int num(CFTypeRef v, int64_t *out) {
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return 0;
    return CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, out);
}

static Boolean set_int(IOHIDServiceClientRef s, CFStringRef key, int64_t v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
    Boolean ok = IOHIDServiceClientSetProperty(s, key, n);
    CFRelease(n);
    return ok;
}

static int64_t read_int(IOHIDServiceClientRef s, CFStringRef key, int64_t fallback) {
    CFTypeRef v = IOHIDServiceClientCopyProperty(s, key);
    int64_t x = fallback;
    if (v) { num(v, &x); CFRelease(v); }
    return x;
}

int rz_set_pointer_acceleration(uint16_t productID, int enabled) {
    IOHIDEventSystemClientRef c = client();
    if (!c) return -1;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(c);
    if (!services) return -2;

    // System-wide acceleration, used to restore a service we had set to -1.
    int64_t systemAccel = 45056;   // macOS default (0.6875 as IOFixed)
    CFTypeRef sv = IOHIDEventSystemClientCopyProperty(c, MOUSE_ACCEL_KEY);
    if (sv) { int64_t x; if (num(sv, &x) && x >= 0) systemAccel = x; CFRelease(sv); }

    int matched = 0, verified = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!IOHIDServiceClientConformsTo(s, 0x01, 0x02)) continue;   // Generic Desktop / Mouse
        if (read_int(s, CFSTR("VendorID"), 0) != RAZER_VID) continue;
        if (read_int(s, CFSTR("ProductID"), 0) != productID) continue;
        matched++;

        CFTypeRef linear = IOHIDServiceClientCopyProperty(s, LINEAR_KEY);
        if (linear) {
            CFRelease(linear);
            set_int(s, LINEAR_KEY, enabled ? 0 : 1);
            if (read_int(s, LINEAR_KEY, -1) == (enabled ? 0 : 1)) verified++;
            continue;
        }
        // Older path: write the acceleration value itself.
        CFStringRef key = MOUSE_ACCEL_KEY;
        CFTypeRef type = IOHIDServiceClientCopyProperty(s, ACCEL_TYPE_KEY);
        if (type && CFGetTypeID(type) == CFStringGetTypeID()) key = (CFStringRef)type;
        int64_t want = enabled ? systemAccel : -65536;
        set_int(s, key, want);
        if (read_int(s, key, 0x7fffffff) == want) verified++;
        if (type) CFRelease(type);
    }
    CFRelease(services);
    if (matched == 0) return 0;
    return verified > 0 ? verified : -3;
}

int rz_pointer_acceleration_enabled(uint16_t productID) {
    IOHIDEventSystemClientRef c = client();
    if (!c) return -1;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(c);
    if (!services) return -1;
    int result = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(services) && result < 0; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!IOHIDServiceClientConformsTo(s, 0x01, 0x02)) continue;
        if (read_int(s, CFSTR("VendorID"), 0) != RAZER_VID || read_int(s, CFSTR("ProductID"), 0) != productID) continue;
        int64_t lin = read_int(s, LINEAR_KEY, -1);
        if (lin >= 0) { result = lin == 1 ? 0 : 1; break; }
        CFStringRef key = MOUSE_ACCEL_KEY;
        CFTypeRef type = IOHIDServiceClientCopyProperty(s, ACCEL_TYPE_KEY);
        if (type && CFGetTypeID(type) == CFStringGetTypeID()) key = (CFStringRef)type;
        result = read_int(s, key, 0) < 0 ? 0 : 1;
        if (type) CFRelease(type);
    }
    CFRelease(services);
    return result;
}

// Minimal Razer USB transport for macOS (IOKit).
// Protocol reference: OpenRazer driver/razercommon.c (GPL-2.0) and librazermacos.
#include "razer_transport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RAZER_VID 0x1532

static int cf_int(io_service_t s, const char *key, int64_t *out) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    if (!v) return 0;
    int ok = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) ok = CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, out);
    CFRelease(v);
    return ok;
}

static void cf_str(io_service_t s, const char *key, char *buf, size_t len) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    if (!v) return;
    if (CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, buf, (CFIndex)len, kCFStringEncodingUTF8);
    CFRelease(v);
}

static io_iterator_t razer_usb_iterator(void) {
    const char *classes[] = { "IOUSBHostDevice", kIOUSBDeviceClassName };
    for (int c = 0; c < 2; c++) {
        CFMutableDictionaryRef match = IOServiceMatching(classes[c]);
        if (!match) continue;
        // Plain top-level property keys don't filter IOUSBHostDevice matching on current macOS,
        // so enumerate every USB device and filter by idVendor in the callers.
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS && it) {
            if (IOIteratorIsValid(it)) {
                io_service_t probe = IOIteratorNext(it);
                if (probe) { IOObjectRelease(probe); IOIteratorReset(it); return it; }
            }
            IOObjectRelease(it);
        }
    }
    return 0;
}

int rz_list_devices(rz_device_info *out, int max) {
    io_iterator_t it = razer_usb_iterator();
    if (!it) return 0;
    int count = 0;
    io_service_t s;
    // Check the room first: IOIteratorNext hands back a retained object that must be released.
    while (count < max && (s = IOIteratorNext(it))) {
        int64_t vid = 0, pid = 0, loc = 0;
        cf_int(s, "idVendor", &vid);
        if (vid != RAZER_VID) { IOObjectRelease(s); continue; }
        cf_int(s, "idProduct", &pid);
        cf_int(s, "locationID", &loc);
        rz_device_info *d = &out[count++];
        memset(d, 0, sizeof(*d));
        d->productID = (uint16_t)pid;
        d->locationID = (uint32_t)loc;
        cf_str(s, "USB Product Name", d->product, sizeof(d->product));
        if (!d->product[0]) cf_str(s, "kUSBProductString", d->product, sizeof(d->product));
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return count;
}

// ---------- Path 1: raw USB control transfer (what librazermacos / razer-macos use) ----------

static int usb_transfer(uint32_t locationID, uint16_t productID, uint16_t idx,
                        const uint8_t *req, uint8_t *resp, uint32_t wait_us) {
    io_iterator_t it = razer_usb_iterator();
    if (!it) return -1;
    io_service_t s, found = 0;
    while ((s = IOIteratorNext(it))) {
        int64_t vid = 0, pid = 0, loc = 0;
        cf_int(s, "idVendor", &vid);
        cf_int(s, "idProduct", &pid);
        cf_int(s, "locationID", &loc);
        if (vid == RAZER_VID && (uint16_t)pid == productID && (locationID == 0 || (uint32_t)loc == locationID)) { found = s; break; }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) return -2;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(found, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(found);
    if (kr != KERN_SUCCESS || !plug) return kr ? kr : -3;

    // 182+ interface for DeviceRequestTO, so a mouse that stops answering can't block the queue.
    IOUSBDeviceInterface182 **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr || !dev) return -4;

    // Opening is best-effort: class requests to an interface usually work without exclusive open.
    IOReturn openRet = (*dev)->USBDeviceOpen(dev);

    uint8_t out[RZ_REPORT_LEN];
    memcpy(out, req, RZ_REPORT_LEN);
    IOUSBDevRequestTO r;
    memset(&r, 0, sizeof(r));
    r.noDataTimeout = 1000; r.completionTimeout = 1000;   // ms
    r.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface); // 0x21
    r.bRequest = 0x09;   // HID SET_REPORT
    r.wValue = 0x0300;   // feature report, id 0
    r.wIndex = idx;
    r.wLength = RZ_REPORT_LEN;
    r.pData = out;
    IOReturn ret = (*dev)->DeviceRequestTO(dev, &r);

    if (ret == kIOReturnSuccess) {
        usleep(wait_us);
        uint8_t in[RZ_REPORT_LEN];
        memset(in, 0, sizeof(in));
        memset(&r, 0, sizeof(r));
        r.noDataTimeout = 1000; r.completionTimeout = 1000;
        r.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface); // 0xA1
        r.bRequest = 0x01;   // HID GET_REPORT
        r.wValue = 0x0300;
        r.wIndex = idx;
        r.wLength = RZ_REPORT_LEN;
        r.pData = in;
        ret = (*dev)->DeviceRequestTO(dev, &r);
        if (ret == kIOReturnSuccess) memcpy(resp, in, RZ_REPORT_LEN);
    }

    if (openRet == kIOReturnSuccess) (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return ret;
}

// ---------- Path 2: IOHID feature reports ----------

// Created on first use and kept for the life of the process. Only touched from the caller's
// serial queue (rz_transfer is not re-entrant).
static IOHIDManagerRef g_mgr = NULL;

static int hid_transfer(uint32_t locationID, uint16_t productID,
                        const uint8_t *req, uint8_t *resp, uint32_t wait_us) {
    if (!g_mgr) {
        g_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        if (!g_mgr) return -10;
    }
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int32_t vid = RAZER_VID, pid = productID;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), nv);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), np);
    CFRelease(nv); CFRelease(np);
    IOHIDManagerSetDeviceMatching(g_mgr, match);
    CFRelease(match);

    CFSetRef set = IOHIDManagerCopyDevices(g_mgr);
    if (!set) return -11;
    CFIndex n = CFSetGetCount(set);
    if (n == 0) { CFRelease(set); return -12; }
    const void **devs = calloc((size_t)n, sizeof(void *));
    if (!devs) { CFRelease(set); return -15; }
    CFSetGetValues(set, devs);

    int result = -13;
    // Two passes: the mouse interface (usage page 1 / usage 2) first, then anything else.
    for (int pass = 0; pass < 2 && result != 0; pass++) {
        for (CFIndex i = 0; i < n && result != 0; i++) {
            IOHIDDeviceRef d = (IOHIDDeviceRef)devs[i];
            int32_t up = 0, u = 0, loc = 0;
            CFTypeRef v;
            if ((v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsagePageKey)))) CFNumberGetValue(v, kCFNumberSInt32Type, &up);
            if ((v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsageKey)))) CFNumberGetValue(v, kCFNumberSInt32Type, &u);
            if ((v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDLocationIDKey)))) CFNumberGetValue(v, kCFNumberSInt32Type, &loc);
            if (locationID && (uint32_t)loc != locationID && ((uint32_t)loc & 0xFFFF0000u) != (locationID & 0xFFFF0000u)) continue;
            int isMouse = (up == 1 && u == 2);
            if ((pass == 0) != isMouse) continue;
            if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
            IOReturn r = IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0, req, RZ_REPORT_LEN);
            if (r == kIOReturnSuccess) {
                usleep(wait_us);
                uint8_t in[RZ_REPORT_LEN];
                memset(in, 0, sizeof(in));
                CFIndex len = RZ_REPORT_LEN;
                r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 0, in, &len);
                if (r == kIOReturnSuccess && len >= RZ_REPORT_LEN - 1) {
                    // Some stacks prepend the report id; normalize to 90 bytes.
                    if (len == RZ_REPORT_LEN) memcpy(resp, in, RZ_REPORT_LEN);
                    else { memset(resp, 0, RZ_REPORT_LEN); memcpy(resp, in, (size_t)len); }
                    result = 0;
                } else result = r ? r : -14;
            } else result = r;
            IOHIDDeviceClose(d, kIOHIDOptionsTypeNone);
        }
    }
    free(devs);
    CFRelease(set);
    return result;
}

int rz_transfer(uint32_t locationID, uint16_t productID, uint16_t interfaceIndex,
                const uint8_t *request, uint8_t *response, uint32_t wait_us, int *path_used) {
    int r = usb_transfer(locationID, productID, interfaceIndex, request, response, wait_us);
    if (r == 0) { if (path_used) *path_used = 1; return 0; }
    int h = hid_transfer(locationID, productID, request, response, wait_us);
    if (h == 0) { if (path_used) *path_used = 2; return 0; }
    if (path_used) *path_used = 0;
    return r;
}

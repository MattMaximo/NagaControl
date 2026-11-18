// Minimal Razer USB transport for macOS.
// Sends the 90-byte Razer feature report (HID SET_REPORT / GET_REPORT, wValue 0x0300)
// the same way OpenRazer (Linux) and librazermacos do.
#ifndef RAZER_TRANSPORT_H
#define RAZER_TRANSPORT_H

#include <stdint.h>

#define RZ_REPORT_LEN 90
#define RZ_MAX_DEVICES 16

typedef struct {
    uint16_t productID;
    uint32_t locationID;
    char product[128];
} rz_device_info;

/// Lists attached USB devices with vendor 0x1532 (Razer). Returns count.
int rz_list_devices(rz_device_info *out, int max);

/// Sends `request` (90 bytes) then reads the 90-byte response into `response`.
/// Tries the raw USB control-transfer path first, then falls back to IOHID feature reports.
/// `path_used` receives 1 for USB, 2 for HID. Returns 0 on success, else an IOReturn/negative code.
/// Call from one thread at a time (the app uses a serial queue).
int rz_transfer(uint32_t locationID, uint16_t productID, uint16_t interfaceIndex,
                const uint8_t *request, uint8_t *response, uint32_t wait_us, int *path_used);

/// Turns macOS pointer acceleration on/off for every pointer service of this Razer mouse
/// (pointer_accel.c). Returns services verified (>0), 0 if the mouse has no pointer service,
/// negative on failure.
int rz_set_pointer_acceleration(uint16_t productID, int enabled);

/// 1 = acceleration on, 0 = off (linear), -1 = unknown / mouse not found.
int rz_pointer_acceleration_enabled(uint16_t productID);

#endif

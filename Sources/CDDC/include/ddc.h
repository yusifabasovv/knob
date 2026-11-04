#ifndef CDDC_H
#define CDDC_H

#include <stdint.h>

/// Opaque handle to an external display's IOAVService (a retained CFTypeRef).
typedef const void *DDCServiceRef;

/// Result codes shared by the read/write calls.
enum {
    DDC_OK = 0,
    DDC_NO_REPLY = -1,      // monitor did not answer (DDC/CI off, wrong input, cable/port without DDC)
    DDC_UNSUPPORTED = -2,   // monitor answered "unsupported VCP code"
};

/// Number of external displays exposing an IOAVService.
int ddc_external_count(void);

/// Retained service for the external display at `index`, or NULL. Release with ddc_release.
/// If `edidUUID` is non-NULL it receives the display's EDID UUID (identifies the monitor model,
/// e.g. "05E30124-0000-0000-191D-010380341D78"), or "" if the registry doesn't expose one.
DDCServiceRef ddc_copy_external_service(int index, char *edidUUID, int edidUUIDLength);
void ddc_release(DDCServiceRef service);

/// Read a VCP feature. On DDC_OK, *current and *maximum are filled.
int ddc_get_vcp(DDCServiceRef service, uint8_t code, uint16_t *current, uint16_t *maximum);

/// Write a VCP feature (one send, no read-back). Includes the DDC/CI post-write pause.
int ddc_set_vcp(DDCServiceRef service, uint8_t code, uint16_t value);

/// Poll (single-attempt reads) until the monitor reports `value`, for up to `timeoutMs`.
/// DDC_OK once it does; DDC_NO_REPLY on timeout (write lost, still applying, or refused).
int ddc_await_vcp(DDCServiceRef service, uint8_t code, uint16_t value, int timeoutMs);

/// Write, then await read-back of `value` (up to `attempts` writes, 400 ms each).
/// Needed because the I2C bus is shared: another DDC client (or a busy monitor) can make a
/// write silently vanish. Returns DDC_OK once confirmed, DDC_NO_REPLY if it never stuck.
int ddc_set_vcp_verified(DDCServiceRef service, uint8_t code, uint16_t value, int attempts);

/// Read the full capabilities string into `buffer` (NUL-terminated).
/// Returns its length, or DDC_NO_REPLY if nothing could be read.
int ddc_read_capabilities(DDCServiceRef service, char *buffer, int bufferLength);

#endif

#include "ddc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Private IOKit symbols used on Apple Silicon for display I2C (same ones MonitorControl / m1ddc use).
typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset,
                                   void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress,
                                    void *inputBuffer, uint32_t inputBufferSize);

#define DDC_CHIP 0x37        // 7-bit I2C address of the display (0x6E write / 0x6F read)
#define DDC_HOST 0x51        // host source address

// Timing, measured on the AOC 24G1WG4 (2026-11-05): a raw I2C write takes ~5 ms and a read ~7 ms;
// single-send requests with a 40 ms reply wait answered 90/90 (even 20 ms did). 40 ms is the DDC/CI
// minimum before reading a reply, so we stay there rather than at the edge. Dropped messages are
// recovered by retries and by read-back verification, not by sending every message twice.
#define REPLY_WAIT_US 40000  // after a request, before reading the reply
#define POST_SET_US 50000    // after a Set VCP, before the next message (DDC/CI)
#define READ_ATTEMPTS 5

// Randomised retry pause. Two DDC clients on one bus that retry on the same fixed schedule
// collide in lockstep (measured: 24% of reads failed even after 4 fixed-delay retries).
static void backoff(void) { usleep(15000 + arc4random_uniform(60000)); } // 15–75 ms

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int is_external(io_service_t s) {
    CFStringRef loc = IORegistryEntryCreateCFProperty(s, CFSTR("Location"), kCFAllocatorDefault, 0);
    int ext = loc && CFGetTypeID(loc) == CFStringGetTypeID() &&
              CFStringCompare(loc, CFSTR("External"), 0) == kCFCompareEqualTo;
    if (loc) CFRelease(loc);
    return ext;
}

// Walk the IOService plane in tree order and find the external DCPAVServiceProxy at `want`
// (or just count them if want < 0). Each display's framebuffer entry, which carries the
// "EDID UUID" property, comes before its DCP AV service in the tree, so the last UUID seen is
// the one that belongs to the next external service (the pairing MonitorControl relies on too).
static int walk_external(int want, IOAVServiceRef *out, char *uuid, int uuidLength) {
    io_iterator_t it;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS)
        return 0;
    char last[64] = "";
    int n = 0;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        CFTypeRef u = IORegistryEntryCreateCFProperty(e, CFSTR("EDID UUID"), kCFAllocatorDefault, 0);
        if (u) {
            if (CFGetTypeID(u) != CFStringGetTypeID() ||
                !CFStringGetCString((CFStringRef)u, last, sizeof last, kCFStringEncodingUTF8))
                last[0] = 0;
            CFRelease(u);
        }
        if (IOObjectConformsTo(e, "DCPAVServiceProxy") && is_external(e)) {
            if (n == want) {
                if (out) *out = IOAVServiceCreateWithService(kCFAllocatorDefault, e);
                if (uuid && uuidLength > 0) snprintf(uuid, (size_t)uuidLength, "%s", last);
            }
            n++;
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return n;
}

int ddc_external_count(void) { return walk_external(-1, NULL, NULL, 0); }

DDCServiceRef ddc_copy_external_service(int index, char *edidUUID, int edidUUIDLength) {
    IOAVServiceRef svc = NULL;
    if (edidUUID && edidUUIDLength > 0) edidUUID[0] = 0;
    walk_external(index, &svc, edidUUID, edidUUIDLength);
    return svc;
}

void ddc_release(DDCServiceRef service) {
    if (service) CFRelease((CFTypeRef)service);
}

static void build_packet(const uint8_t *payload, int n, uint8_t *pkt) {
    pkt[0] = 0x80 | (uint8_t)n;
    memcpy(pkt + 1, payload, (size_t)n);
    uint8_t chk = 0x6E ^ DDC_HOST ^ pkt[0];
    for (int i = 0; i < n; i++) chk ^= payload[i];
    pkt[n + 1] = chk;
}

static int send_payload(IOAVServiceRef svc, const uint8_t *payload, int n) {
    uint8_t pkt[40];
    build_packet(payload, n, pkt);
    return IOAVServiceWriteI2C(svc, DDC_CHIP, DDC_HOST, pkt, (uint32_t)(n + 2)) == kIOReturnSuccess;
}

// One request/reply round trip. Returns the reply payload length (reply[1] & 0x7F) or DDC_NO_REPLY.
static int transact_once(IOAVServiceRef svc, const uint8_t *payload, int n, uint8_t *reply, int rlen) {
    if (!send_payload(svc, payload, n)) return DDC_NO_REPLY;
    usleep(REPLY_WAIT_US);
    memset(reply, 0, (size_t)rlen);
    if (IOAVServiceReadI2C(svc, DDC_CHIP, DDC_HOST, reply, (uint32_t)rlen) != kIOReturnSuccess) return DDC_NO_REPLY;
    int len = reply[1] & 0x7F;
    if (len + 3 > rlen) return DDC_NO_REPLY;
    uint8_t c = 0x50; // reply checksum seed: virtual host address
    for (int i = 0; i < len + 2; i++) c ^= reply[i];
    return c == reply[len + 2] ? len : DDC_NO_REPLY;
}

static int get_vcp(IOAVServiceRef svc, uint8_t code, uint16_t *current, uint16_t *maximum, int attempts) {
    uint8_t p[2] = {0x01, code}, r[12];
    for (int i = 0; i < attempts; i++) {
        if (i) backoff();
        int len = transact_once(svc, p, 2, r, sizeof r);
        if (len < 8 || r[2] != 0x02 || r[4] != code) continue; // no, corrupt or foreign reply
        if (r[3] != 0) return DDC_UNSUPPORTED;
        if (maximum) *maximum = (uint16_t)((r[6] << 8) | r[7]);
        if (current) *current = (uint16_t)((r[8] << 8) | r[9]);
        return DDC_OK;
    }
    return DDC_NO_REPLY;
}

int ddc_get_vcp(DDCServiceRef service, uint8_t code, uint16_t *current, uint16_t *maximum) {
    if (!service) return DDC_NO_REPLY;
    return get_vcp((IOAVServiceRef)service, code, current, maximum, READ_ATTEMPTS);
}

int ddc_set_vcp(DDCServiceRef service, uint8_t code, uint16_t value) {
    if (!service) return DDC_NO_REPLY;
    uint8_t p[4] = {0x03, code, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF)};
    int ok = send_payload((IOAVServiceRef)service, p, 4);
    usleep(POST_SET_US);
    return ok ? DDC_OK : DDC_NO_REPLY;
}

int ddc_await_vcp(DDCServiceRef service, uint8_t code, uint16_t value, int timeoutMs) {
    if (!service) return DDC_NO_REPLY;
    double deadline = now_ms() + timeoutMs;
    do {
        uint16_t cur = 0;
        int rc = get_vcp((IOAVServiceRef)service, code, &cur, NULL, 1);
        if (rc == DDC_OK && cur == value) return DDC_OK;
        if (rc == DDC_UNSUPPORTED) return DDC_UNSUPPORTED;
        usleep(5000 + arc4random_uniform(25000)); // monitor still applying, or a bus collision
    } while (now_ms() < deadline);
    return DDC_NO_REPLY;
}

int ddc_set_vcp_verified(DDCServiceRef service, uint8_t code, uint16_t value, int attempts) {
    for (int i = 0; i < attempts; i++) {
        if (ddc_set_vcp(service, code, value) != DDC_OK) { backoff(); continue; }
        int rc = ddc_await_vcp(service, code, value, 400);
        if (rc == DDC_OK || rc == DDC_UNSUPPORTED) return rc;
    }
    return DDC_NO_REPLY;
}

int ddc_read_capabilities(DDCServiceRef service, char *buffer, int bufferLength) {
    if (!service || bufferLength < 2) return DDC_NO_REPLY;
    IOAVServiceRef svc = (IOAVServiceRef)service;
    int total = 0, fails = 0;
    buffer[0] = 0;
    while (total < bufferLength - 40) {
        uint8_t p[3] = {0xF3, (uint8_t)(total >> 8), (uint8_t)(total & 0xFF)}, r[40];
        int len = transact_once(svc, p, 3, r, 38);
        if (len < 3 || r[2] != 0xE3 || ((r[3] << 8) | r[4]) != total) {
            if (++fails > 6) break;
            backoff();
            continue;
        }
        int dlen = len - 3;
        if (dlen <= 0) break; // empty fragment = end of string
        memcpy(buffer + total, r + 5, (size_t)dlen);
        total += dlen;
        // Some monitors NUL-terminate inside the last fragment.
        if (memchr(r + 5, 0, (size_t)dlen)) break;
    }
    buffer[total] = 0;
    total = (int)strlen(buffer);
    return total > 0 ? total : DDC_NO_REPLY;
}

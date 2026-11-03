#ifndef EASL_STALL_TIMER_H
#define EASL_STALL_TIMER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EaslStallTimer EaslStallTimer;

// Owns one Mach timer receive right. NULL means allocation or Mach setup failed.
EaslStallTimer *easl_stall_timer_create(void);
// Borrowed receive right, valid until destroy. Use only for the Mach receive source.
uint32_t easl_stall_timer_port(const EaslStallTimer *timer);
// Absolute CLOCK_UPTIME_RAW nanoseconds; zero cancels without draining queued fires.
// Returns the Mach arm/cancel result, or KERN_INVALID_ARGUMENT if ticks overflow.
// Order set calls externally. They may overlap take on one serial receive source.
int32_t easl_stall_timer_set(EaslStallTimer *timer, uint64_t deadline_ns);
// Nonblocking receive of one expiry: KERN_SUCCESS, MACH_RCV_TIMED_OUT, or Mach error.
// An unexpected consumed message is destroyed and returns MACH_RCV_INVALID_DATA.
// Oversized messages stay queued. On errors other than timeout, cancel the source.
int32_t easl_stall_timer_take(EaslStallTimer *timer);
// NULL is allowed. Otherwise all calls must have finished; no concurrent destroy.
// The Swift receive source must destroy from its cancel handler, after its event
// handler has finished, never immediately after requesting source cancellation.
void easl_stall_timer_destroy(EaslStallTimer *timer);

#ifdef __cplusplus
}
#endif

#endif

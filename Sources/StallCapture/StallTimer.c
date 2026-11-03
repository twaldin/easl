#define _DARWIN_C_SOURCE 1

#include "StallTimer.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdlib.h>

_Static_assert(sizeof(uintptr_t) == 8, "StallTimer requires LP64");

// CoreFoundation uses the uint64_t arm ABI; XNU's mach/mk_timer.h declares all four.
extern mach_port_name_t mk_timer_create(void);
extern kern_return_t mk_timer_destroy(mach_port_name_t name);
extern kern_return_t mk_timer_arm(mach_port_name_t name, uint64_t expire_time);
extern kern_return_t mk_timer_cancel(mach_port_name_t name, uint64_t *result_time);

struct EaslStallTimer {
    mach_port_name_t port;
    mach_timebase_info_data_t timebase;
};

EaslStallTimer *easl_stall_timer_create(void) {
    EaslStallTimer *timer = calloc(1, sizeof(*timer));
    if (!timer) return NULL;
    if (mach_timebase_info(&timer->timebase) != KERN_SUCCESS ||
        !timer->timebase.numer || !timer->timebase.denom) {
        free(timer);
        return NULL;
    }
    timer->port = mk_timer_create();
    if (!MACH_PORT_VALID(timer->port)) {
        free(timer);
        return NULL;
    }
    return timer;
}

uint32_t easl_stall_timer_port(const EaslStallTimer *timer) {
    return timer->port;
}

int32_t easl_stall_timer_set(EaslStallTimer *timer, uint64_t deadline_ns) {
    if (!deadline_ns) return mk_timer_cancel(timer->port, NULL);
    __uint128_t ticks = (__uint128_t)deadline_ns * timer->timebase.denom /
                        timer->timebase.numer;
    if (ticks > UINT64_MAX) return KERN_INVALID_ARGUMENT;
    return mk_timer_arm(timer->port, (uint64_t)ticks);
}

int32_t easl_stall_timer_take(EaslStallTimer *timer) {
    // XNU's mk_timer_expire_msg_t has three unused uint64_t words after the header.
    struct {
        mach_msg_header_t header;
        uint64_t unused[3];
        mach_msg_max_trailer_t trailer;
    } message;
    mach_msg_return_t result = mach_msg(&message.header,
        MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE, 0, sizeof(message),
        timer->port, 0, MACH_PORT_NULL);
    if (result != MACH_MSG_SUCCESS) {
        // A body copyout error can still deliver rights or out-of-line memory.
        if ((result & ~MACH_MSG_MASK) == MACH_RCV_BODY_ERROR) {
            mach_msg_destroy(&message.header);
        }
        return result;
    }
    bool is_expiry = message.header.msgh_size ==
                         sizeof(mach_msg_header_t) + 3 * sizeof(uint64_t) &&
                     !(message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX);
    // This also releases rights or out-of-line memory in unexpected messages.
    mach_msg_destroy(&message.header);
    return is_expiry ? KERN_SUCCESS : MACH_RCV_INVALID_DATA;
}

void easl_stall_timer_destroy(EaslStallTimer *timer) {
    if (!timer) return;
    mk_timer_destroy(timer->port);
    free(timer);
}

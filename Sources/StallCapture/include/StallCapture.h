#ifndef EASL_STALL_CAPTURE_H
#define EASL_STALL_CAPTURE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EASL_STALL_FRAME_CAPACITY 64
#define EASL_STALL_WALK_BUDGET_NS UINT64_C(2000000)
#define EASL_STALL_CPU_BRACKET_NS UINT64_C(5000000)
#define EASL_STALL_EXIT_RESUME_FAILED 86

typedef struct EaslStallCapture EaslStallCapture;

enum {
    EASL_STALL_ERROR_ARGUMENT = -1,
    EASL_STALL_ERROR_TURN_CHANGED = -2,
    EASL_STALL_ERROR_MAIN_THREAD = -3,
    EASL_STALL_ERROR_SLEEP = -4,
    EASL_STALL_ERROR_SHORT_INFO = -5,
    EASL_STALL_ERROR_SHORT_STATE = -6,
    EASL_STALL_ERROR_ZERO_PC = -7,
    EASL_STALL_ERROR_SHORT_READ = -8
};

enum {
    EASL_STALL_WALK_NOT_STARTED = 0,
    EASL_STALL_WALK_END = 1,
    EASL_STALL_WALK_LIMIT = 2,
    EASL_STALL_WALK_BUDGET = 3,
    EASL_STALL_WALK_STACK_RANGE = 4,
    EASL_STALL_WALK_INVALID_FRAME = 5,
    EASL_STALL_WALK_READ_ERROR = 6,
    EASL_STALL_WALK_SHORT_READ = 7
};

typedef struct {
    uint64_t captured_ns;
    uint64_t bracket_ns;
    uint64_t cpu_ns;
    int run_state;
    int suspend_count;
    int error;
    uint32_t frame_count;
    uintptr_t frames[EASL_STALL_FRAME_CAPACITY];
    uint64_t suspend_ns;
    int walk_status;
} EaslStallRecord;

// Create on main. NULL means capture setup is unavailable; no permissions change.
EaslStallCapture *easl_stall_create(void);
// Destroy only after all capture and publication calls have finished.
void easl_stall_destroy(EaslStallCapture *capture);
// Use distinct nonzero turn tokens; zero means sleeping.
void easl_stall_publish(EaslStallCapture *capture, uint64_t turn);
// Call serially off main. Output is caller-owned and reset even on failure.
// True requires the expected nonzero token while suspended and a captured PC.
// error is zero, a raw Mach error, or a named EASL_STALL_ERROR value.
// Partial walks can return true with an error. Timestamps use CLOCK_UPTIME_RAW;
// suspend_ns includes suspend/resume calls. Failed resume terminates with 86.
bool easl_stall_capture(EaslStallCapture *capture, uint64_t expected,
                        EaslStallRecord *out);

#ifdef __cplusplus
}
#endif

#endif

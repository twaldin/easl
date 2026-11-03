#define _DARWIN_C_SOURCE 1

#include "StallCapture.h"

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#elif defined(__x86_64__)
#include <mach/i386/thread_status.h>
#else
#error StallCapture requires arm64 or x86_64 macOS
#endif

_Static_assert(sizeof(uintptr_t) == 8, "StallCapture requires 64-bit pointers");
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
               "Suspended capture requires lock-free turn publication");


struct EaslStallCapture {
    _Atomic(uint64_t) turn;
    thread_t main_thread;
    mach_port_t task;
    uintptr_t stack_low;
    uintptr_t stack_high;
};

static inline __attribute__((always_inline)) uintptr_t strip_code_pointer(uintptr_t value) {
#if defined(__arm64__) && __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_return_address);
#elif defined(__arm64__)
    uintptr_t stripped;
    // Plain arm64 can encounter signed return addresses in arm64e system images.
    __asm__ volatile("mov x30, %1\n\thint #7\n\tmov %0, x30"
                     : "=r"(stripped) : "r"(value) : "x30");
    return stripped;
#else
    return value;
#endif
}

static inline __attribute__((always_inline)) uintptr_t strip_frame_pointer(uintptr_t value) {
#if defined(__arm64__)
    value &= ~(UINT64_C(1) << 60);
#if __has_feature(ptrauth_calls)
    value = (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_process_independent_data);
#endif
#endif
    return value;
}

static uint64_t cpu_ns(const thread_basic_info_data_t *info) {
    return ((uint64_t)info->user_time.seconds + (uint64_t)info->system_time.seconds) *
               UINT64_C(1000000000) +
           ((uint64_t)info->user_time.microseconds + (uint64_t)info->system_time.microseconds) *
               UINT64_C(1000);
}

EaslStallCapture *easl_stall_create(void) {
    if (!pthread_main_np()) return NULL;
    EaslStallCapture *capture = calloc(1, sizeof(*capture));
    if (!capture) return NULL;
    atomic_init(&capture->turn, 0);
    capture->task = mach_task_self();
    capture->main_thread = mach_thread_self();
    capture->stack_high = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t stack_size = pthread_get_stacksize_np(pthread_self());
    if (!capture->main_thread || !capture->stack_high ||
        stack_size < 2 * sizeof(uintptr_t) || stack_size > capture->stack_high) {
        easl_stall_destroy(capture);
        return NULL;
    }
    capture->stack_low = capture->stack_high - stack_size;
    return capture;
}

void easl_stall_destroy(EaslStallCapture *capture) {
    if (!capture) return;
    if (capture->main_thread) mach_port_deallocate(capture->task, capture->main_thread);
    free(capture);
}

void easl_stall_publish(EaslStallCapture *capture, uint64_t turn) {
    if (capture) atomic_store_explicit(&capture->turn, turn, memory_order_seq_cst);
}

bool easl_stall_capture(EaslStallCapture *capture, uint64_t expected, EaslStallRecord *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    if (!capture || !expected) {
        out->error = EASL_STALL_ERROR_ARGUMENT;
        return false;
    }
    if (pthread_main_np()) {
        out->error = EASL_STALL_ERROR_MAIN_THREAD;
        return false;
    }
    if (atomic_load_explicit(&capture->turn, memory_order_seq_cst) != expected) {
        out->error = EASL_STALL_ERROR_TURN_CHANGED;
        return false;
    }

    thread_basic_info_data_t before = {0};
    thread_basic_info_data_t after = {0};
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    out->error = thread_info(capture->main_thread, THREAD_BASIC_INFO,
                             (thread_info_t)&before, &count);
    if (out->error != KERN_SUCCESS) return false;
    if (count < THREAD_BASIC_INFO_COUNT) {
        out->error = EASL_STALL_ERROR_SHORT_INFO;
        return false;
    }
    uint64_t bracket_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    struct timespec delay = { .tv_sec = 0, .tv_nsec = EASL_STALL_CPU_BRACKET_NS };
    if (nanosleep(&delay, NULL) != 0) {
        out->error = EASL_STALL_ERROR_SLEEP;
        return false;
    }
    count = THREAD_BASIC_INFO_COUNT;
    out->error = thread_info(capture->main_thread, THREAD_BASIC_INFO,
                             (thread_info_t)&after, &count);
    out->bracket_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - bracket_start;
    if (out->error != KERN_SUCCESS) return false;
    if (count < THREAD_BASIC_INFO_COUNT) {
        out->error = EASL_STALL_ERROR_SHORT_INFO;
        return false;
    }
    uint64_t before_cpu = cpu_ns(&before);
    uint64_t after_cpu = cpu_ns(&after);
    out->cpu_ns = after_cpu >= before_cpu ? after_cpu - before_cpu : 0;
    out->run_state = after.run_state;
    out->suspend_count = after.suspend_count;
    if (atomic_load_explicit(&capture->turn, memory_order_seq_cst) != expected) {
        out->error = EASL_STALL_ERROR_TURN_CHANGED;
        return false;
    }

#if defined(__arm64__)
    arm_thread_state64_t state = {0};
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    const thread_state_flavor_t flavor = ARM_THREAD_STATE64;
    const mach_msg_type_number_t expected_count = ARM_THREAD_STATE64_COUNT;
#else
    x86_thread_state64_t state = {0};
    mach_msg_type_number_t state_count = x86_THREAD_STATE64_COUNT;
    const thread_state_flavor_t flavor = x86_THREAD_STATE64;
    const mach_msg_type_number_t expected_count = x86_THREAD_STATE64_COUNT;
#endif
    uintptr_t pair[2] = {0};
    mach_vm_size_t read_size = 0;
    uintptr_t pc = 0;
    uintptr_t fp = 0;
    uintptr_t sp = 0;
    bool accepted = false;
    uintptr_t lr = 0;
    uint64_t suspend_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    out->error = thread_suspend(capture->main_thread);
    if (out->error != KERN_SUCCESS) return false;

    out->captured_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (atomic_load_explicit(&capture->turn, memory_order_seq_cst) != expected) {
        out->error = EASL_STALL_ERROR_TURN_CHANGED;
        goto resume_main;
    }
    count = THREAD_BASIC_INFO_COUNT;
    out->error = thread_info(capture->main_thread, THREAD_BASIC_INFO,
                                  (thread_info_t)&after, &count);
    if (out->error != KERN_SUCCESS) goto resume_main;
    if (count < THREAD_BASIC_INFO_COUNT) {
        out->error = EASL_STALL_ERROR_SHORT_INFO;
        goto resume_main;
    }
    after_cpu = cpu_ns(&after);
    out->cpu_ns = after_cpu >= before_cpu ? after_cpu - before_cpu : 0;
    out->bracket_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - bracket_start;
    out->error = thread_get_state(capture->main_thread, flavor,
                                    (thread_state_t)&state, &state_count);
    if (out->error != KERN_SUCCESS) goto resume_main;
    if (state_count < expected_count) {
        out->error = EASL_STALL_ERROR_SHORT_STATE;
        goto resume_main;
    }
#if defined(__arm64__)
    arm_thread_state64_ptrauth_strip(state);
    pc = strip_code_pointer((uintptr_t)arm_thread_state64_get_pc(state));
    fp = strip_frame_pointer((uintptr_t)arm_thread_state64_get_fp(state));
    sp = strip_frame_pointer((uintptr_t)arm_thread_state64_get_sp(state));
    lr = strip_code_pointer((uintptr_t)arm_thread_state64_get_lr(state));
#else
    pc = (uintptr_t)state.__rip;
    fp = (uintptr_t)state.__rbp;
    sp = (uintptr_t)state.__rsp;
#endif
    if (!pc) {
        out->error = EASL_STALL_ERROR_ZERO_PC;
        goto resume_main;
    }
    out->frames[out->frame_count++] = pc;
    if (lr && lr != pc) {
        out->frames[out->frame_count++] = lr;
        out->has_link_register = true;
    }
    accepted = true;
    if (sp < capture->stack_low || sp >= capture->stack_high) {
        out->walk_status = EASL_STALL_WALK_STACK_RANGE;
        goto resume_main;
    }
    while (out->frame_count < EASL_STALL_FRAME_CAPACITY) {
        if (!fp) {
            out->walk_status = EASL_STALL_WALK_END;
            goto resume_main;
        }
        if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - out->captured_ns >= EASL_STALL_WALK_BUDGET_NS) {
            out->walk_status = EASL_STALL_WALK_BUDGET;
            goto resume_main;
        }
        if (fp < sp || fp < capture->stack_low ||
            fp > capture->stack_high - sizeof(pair) || (fp & (sizeof(uintptr_t) - 1))) {
            out->walk_status = EASL_STALL_WALK_INVALID_FRAME;
            goto resume_main;
        }
        read_size = 0;
        out->error = mach_vm_read_overwrite(capture->task, (mach_vm_address_t)fp, sizeof(pair),
                                         (mach_vm_address_t)(uintptr_t)pair, &read_size);
        if (out->error != KERN_SUCCESS) {
            out->walk_status = EASL_STALL_WALK_READ_ERROR;
            goto resume_main;
        }
        if (read_size != sizeof(pair)) {
            out->error = EASL_STALL_ERROR_SHORT_READ;
            out->walk_status = EASL_STALL_WALK_SHORT_READ;
            goto resume_main;
        }
        pc = strip_code_pointer(pair[1]);
        if (!pc) {
            out->walk_status = EASL_STALL_WALK_END;
            goto resume_main;
        }
        if (out->frames[out->frame_count - 1] != pc)
            out->frames[out->frame_count++] = pc;
        uintptr_t next_fp = strip_frame_pointer(pair[0]);
        if (next_fp && next_fp <= fp) {
            out->walk_status = EASL_STALL_WALK_INVALID_FRAME;
            goto resume_main;
        }
        fp = next_fp;
    }
    out->walk_status = EASL_STALL_WALK_LIMIT;

resume_main:
    if (thread_resume(capture->main_thread) != KERN_SUCCESS)
        _exit(EASL_STALL_EXIT_RESUME_FAILED);
    out->suspend_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - suspend_start;
    return accepted;
}

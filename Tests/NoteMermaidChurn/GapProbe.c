#define _DARWIN_C_SOURCE 1

#include <dlfcn.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#elif defined(__x86_64__)
#include <mach/i386/thread_status.h>
#else
#error GapProbe requires arm64 or x86_64 macOS
#endif

_Static_assert(sizeof(uintptr_t) == 8, "GapProbe requires 64-bit pointers");
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2 &&
               ATOMIC_INT_LOCK_FREE == 2, "Suspended capture requires lock-free atomics");

void easl_gap_start(const char *fixture);
void easl_gap_context(int edit, int phase);
void easl_gap_beat(void);
void easl_gap_stop(void);

#define GAP_NS UINT64_C(30000000)
#define POLL_NS UINT64_C(5000000)
#define STACK_PERIOD_NS UINT64_C(10000000)
#define WALK_BUDGET_NS UINT64_C(2000000)
#define INTERVAL_CAPACITY 32768
#define OVERFLOW_GAP_CAPACITY 1024
#define CONTEXT_CAPACITY 1024
#define WAKE_CAPACITY 16384
#define STACK_CAPACITY 2048
#define FRAME_CAPACITY 64
#define FIXTURE_CAPACITY 256

typedef struct {
    uint64_t sequence;
    int edit;
    int phase;
} Context;

typedef struct {
    uint64_t at_ns;
    uint64_t end_ns;
    uint64_t user_ns;
    uint64_t system_ns;
    kern_return_t error;
    mach_msg_type_number_t returned_count;
    int run_state;
    int suspend_count;
    int flags;
    int usage;
    bool valid;
} CPU;

typedef struct {
    uint64_t calls;
    uint64_t api_errors;
    uint64_t short_results;
    uint64_t wall_ns;
    kern_return_t last_error;
} CPUStats;

typedef struct {
    uint64_t sequence;
    uint64_t interval_sequence;
    Context start_context;
    Context end_context;
    CPU start;
    CPU end;
} Interval;

typedef struct {
    uint64_t sequence;
    uint64_t interval_sequence;
    Context closed;
    Context next;
    CPU start;
    CPU end;
    bool stopping;
} ContextRecord;

typedef struct {
    atomic_uint_fast64_t publication;
    atomic_uint_fast64_t record_sequence;
    atomic_uint_fast64_t interval_sequence;
    atomic_uint_fast64_t beat_at_ns;
    atomic_uint_fast64_t context_sequence;
    atomic_uint_fast64_t context_at_ns;
    atomic_int edit;
    atomic_int phase;
    atomic_int active;
    atomic_int stop;
} Publication;

typedef struct {
    uint64_t version;
    uint64_t interval_sequence;
    uint64_t beat_at_ns;
    uint64_t context_at_ns;
    Context context;
    bool active;
} Snapshot;

typedef enum {
    SNAPSHOT_STABLE,
    SNAPSHOT_BUSY,
    SNAPSHOT_CHANGED
} SnapshotResult;

typedef struct {
    uint64_t sequence;
    uint64_t due_ns;
    uint64_t wait_start_ns;
    uint64_t at_ns;
    uint64_t snapshot_at_ns;
    uint64_t missed_deadlines;
    kern_return_t wait_error;
    SnapshotResult snapshot_result;
    Snapshot snapshot;
} Wake;

typedef struct {
    uintptr_t raw_pc;
    uintptr_t pc;
    uintptr_t frame_pointer;
} Frame;

typedef enum {
    CAPTURE_PENDING,
    CAPTURE_CANCELLED,
    CAPTURE_RACED,
    CAPTURE_SUSPEND_ERROR,
    CAPTURE_STATE_ERROR,
    CAPTURE_STACK
} CaptureResult;

typedef enum {
    WALK_NOT_STARTED,
    WALK_END,
    WALK_LIMIT,
    WALK_BUDGET,
    WALK_STACK_RANGE,
    WALK_INVALID_FRAME,
    WALK_READ_ERROR,
    WALK_SHORT_READ,
    WALK_ZERO_PC
} WalkResult;

typedef struct {
    uint64_t sequence;
    uint64_t wake_sequence;
    Snapshot candidate;
    CPU pre_suspend_cpu;
    uint64_t at_ns;
    uint64_t suspend_begin_ns;
    uint64_t suspended_ns;
    uint64_t resume_begin_ns;
    uint64_t resume_end_ns;
    uint64_t due_ns;
    uint64_t wake_ns;
    uint64_t wait_start_ns;
    uint64_t observed_version;
    kern_return_t suspend_error;
    kern_return_t state_error;
    kern_return_t read_error;
    kern_return_t first_resume_error;
    mach_msg_type_number_t state_count;
    mach_vm_size_t read_size;
    unsigned resume_attempts;
    CaptureResult result;
    WalkResult walk;
    bool accepted;
    uintptr_t raw_pc;
    uintptr_t raw_lr;
    uintptr_t pc;
    uintptr_t lr;
    uintptr_t sp;
    uintptr_t fp;
    uintptr_t failed_fp;
    unsigned frame_count;
    Frame frames[FRAME_CAPACITY];
} StackRecord;

typedef kern_return_t (*StateFunction)(thread_act_t, thread_state_flavor_t,
                                      thread_state_t, mach_msg_type_number_t *);
typedef kern_return_t (*ReadFunction)(mach_port_t, mach_vm_address_t, mach_vm_size_t,
                                     mach_vm_address_t, mach_vm_size_t *);
typedef kern_return_t (*ResumeFunction)(thread_act_t);
typedef void (*ExitFunction)(int) __attribute__((noreturn));

typedef enum {
    START_OK,
    START_NOT_MAIN,
    START_CLOCK_ERROR,
    START_SYMBOL_ERROR,
    START_STACK_BOUNDS_ERROR,
    START_READ_ERROR,
    START_PTHREAD_ERROR
} StartResult;

typedef struct {
    bool live;
    bool enabled;
    bool watchdog_created;
    bool fixture_truncated;
    uint64_t session_sequence;
    char fixture[FIXTURE_CAPACITY];
    char fixture_json[FIXTURE_CAPACITY * 6 + 3];
    StartResult start_result;
    kern_return_t timebase_error;
    kern_return_t warm_state_error;
    kern_return_t warm_read_error;
    mach_vm_size_t warm_read_size;
    unsigned missing_symbols;
    int create_error;
    int join_error;
    kern_return_t deallocate_error;
    mach_timebase_info_data_t timebase;
    thread_t main_thread;
    mach_port_t task;
    pthread_t watchdog;
    uintptr_t stack_low;
    uintptr_t stack_high;
    StateFunction get_state;
    ReadFunction read_memory;
    ResumeFunction resume;
    ExitFunction exit_process;
    uint64_t start_ns;
    uint64_t stop_ns;
    uint64_t joined_ns;
    uint64_t interval_sequence;
    Context context;
    Context beat_context;
    CPU beat_cpu;
    CPU context_cpu;
    CPUStats cpu_stats;
    uint64_t heartbeat_count;
    uint64_t gap_count;
    uint64_t interval_dropped;
    uint64_t gap_dropped;
    uint64_t context_count;
    uint64_t context_dropped;
    uint64_t lifecycle_errors;
    uint64_t main_probe_wall_ns;
    uint64_t main_probe_max_ns;
    size_t interval_stored;
    size_t overflow_gap_stored;
    size_t context_stored;
} Session;

typedef struct {
    CPUStats cpu_stats;
    uint64_t wake_count;
    uint64_t wake_dropped;
    uint64_t wake_lateness_total_ns;
    uint64_t wake_lateness_max_ns;
    uint64_t wake_lateness_max_at_ns;
    uint64_t wait_overshoot_max_ns;
    uint64_t work_overdue_max_ns;
    uint64_t missed_deadlines;
    uint64_t wait_errors;
    kern_return_t last_wait_error;
    uint64_t snapshot_busy;
    uint64_t snapshot_changed;
    uint64_t stack_count;
    uint64_t stack_dropped;
    uint64_t accepted_stacks;
    uint64_t raced_stacks;
    uint64_t suspend_calls;
    uint64_t suspend_errors;
    kern_return_t last_suspend_error;
    uint64_t state_errors;
    kern_return_t last_state_error;
    uint64_t short_states;
    uint64_t read_errors;
    kern_return_t last_read_error;
    uint64_t short_reads;
    uint64_t resume_errors;
    kern_return_t last_resume_error;
    uint64_t suspend_envelope_total_ns;
    uint64_t suspend_envelope_max_ns;
    int cancel_disable_error;
    int signal_mask_error;
    size_t wake_stored;
    size_t stack_stored;
} WatchdogStats;

static Session session;
static Publication publication;
static WatchdogStats watchdog_stats;
static Interval intervals[INTERVAL_CAPACITY];
static Interval overflow_gaps[OVERFLOW_GAP_CAPACITY];
static ContextRecord contexts[CONTEXT_CAPACITY];
static Wake wakes[WAKE_CAPACITY];
static StackRecord stacks[STACK_CAPACITY];
static bool storage_touched;
static uint64_t session_sequence;

static uint64_t ticks_to_ns(uint64_t ticks) {
    return (uint64_t)(((__uint128_t)ticks * session.timebase.numer) / session.timebase.denom);
}

static uint64_t now_ns(void) {
    return ticks_to_ns(mach_absolute_time());
}

static uint64_t next_sequence(void) {
    return atomic_fetch_add_explicit(&publication.record_sequence, 1, memory_order_relaxed) + 1;
}

static uint64_t positive_difference(uint64_t end, uint64_t start) {
    return end > start ? end - start : 0;
}

static CPU sample_cpu(CPUStats *stats) {
    CPU result = {0};
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    result.at_ns = now_ns();
    result.error = thread_info(session.main_thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count);
    result.end_ns = now_ns();
    result.returned_count = count;
    stats->calls++;
    stats->wall_ns += result.end_ns - result.at_ns;
    if (result.error != KERN_SUCCESS) {
        stats->api_errors++;
        stats->last_error = result.error;
    } else if (count < THREAD_BASIC_INFO_COUNT) {
        stats->short_results++;
    } else {
        result.valid = true;
        result.user_ns = (uint64_t)info.user_time.seconds * UINT64_C(1000000000) +
                         (uint64_t)info.user_time.microseconds * 1000;
        result.system_ns = (uint64_t)info.system_time.seconds * UINT64_C(1000000000) +
                           (uint64_t)info.system_time.microseconds * 1000;
        result.run_state = info.run_state;
        result.suspend_count = info.suspend_count;
        result.flags = info.flags;
        result.usage = info.cpu_usage;
    }
    return result;
}

static void publish(void) {
    atomic_store_explicit(&publication.interval_sequence, session.interval_sequence, memory_order_relaxed);
    atomic_store_explicit(&publication.beat_at_ns, session.beat_cpu.at_ns, memory_order_relaxed);
    atomic_store_explicit(&publication.context_sequence, session.context.sequence, memory_order_relaxed);
    atomic_store_explicit(&publication.context_at_ns, session.context_cpu.at_ns, memory_order_relaxed);
    atomic_store_explicit(&publication.edit, session.context.edit, memory_order_relaxed);
    atomic_store_explicit(&publication.phase, session.context.phase, memory_order_relaxed);
    atomic_fetch_add_explicit(&publication.publication, 1, memory_order_seq_cst);
}

static SnapshotResult read_snapshot(Snapshot *snapshot) {
    uint64_t version = atomic_load_explicit(&publication.publication, memory_order_acquire);
    if (version & 1) return SNAPSHOT_BUSY;
    snapshot->version = version;
    snapshot->interval_sequence = atomic_load_explicit(&publication.interval_sequence, memory_order_relaxed);
    snapshot->beat_at_ns = atomic_load_explicit(&publication.beat_at_ns, memory_order_relaxed);
    snapshot->context.sequence = atomic_load_explicit(&publication.context_sequence, memory_order_relaxed);
    snapshot->context_at_ns = atomic_load_explicit(&publication.context_at_ns, memory_order_relaxed);
    snapshot->context.edit = atomic_load_explicit(&publication.edit, memory_order_relaxed);
    snapshot->context.phase = atomic_load_explicit(&publication.phase, memory_order_relaxed);
    snapshot->active = atomic_load_explicit(&publication.active, memory_order_relaxed) != 0;
    atomic_thread_fence(memory_order_acquire);
    if (atomic_load_explicit(&publication.publication, memory_order_acquire) != version) return SNAPSHOT_CHANGED;
    return SNAPSHOT_STABLE;
}

static uintptr_t strip_code_pointer(uintptr_t value) {
#if defined(__arm64__) && __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_return_address);
#elif defined(__arm64__)
    uintptr_t stripped;
    // An arm64 target can still encounter signed return PCs in arm64e system images.
    __asm__ volatile("mov x30, %1\n\thint #7\n\tmov %0, x30"
                     : "=r"(stripped) : "r"(value) : "x30");
    return stripped;
#else
    return value;
#endif
}

static uintptr_t strip_frame_pointer(uintptr_t value) {
#if defined(__arm64__) && __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_process_independent_data);
#else
    return value;
#endif
}

static void capture_frames(StackRecord *record) {
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t expected = ARM_THREAD_STATE64_COUNT;
    record->state_count = expected;
    record->state_error = session.get_state(session.main_thread, ARM_THREAD_STATE64,
                                             (thread_state_t)&state, &record->state_count);
    if (record->state_error != KERN_SUCCESS || record->state_count < expected) {
        record->result = CAPTURE_STATE_ERROR;
        return;
    }
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
    record->raw_pc = (uintptr_t)state.__opaque_pc;
    record->raw_lr = (uintptr_t)state.__opaque_lr;
#else
    record->raw_pc = (uintptr_t)state.__pc;
    record->raw_lr = (uintptr_t)state.__lr;
#endif
    arm_thread_state64_ptrauth_strip(state);
    record->pc = strip_code_pointer((uintptr_t)arm_thread_state64_get_pc(state));
    record->lr = strip_code_pointer((uintptr_t)arm_thread_state64_get_lr(state));
    record->fp = strip_frame_pointer((uintptr_t)arm_thread_state64_get_fp(state));
    record->sp = strip_frame_pointer((uintptr_t)arm_thread_state64_get_sp(state));
#else
    x86_thread_state64_t state;
    mach_msg_type_number_t expected = x86_THREAD_STATE64_COUNT;
    record->state_count = expected;
    record->state_error = session.get_state(session.main_thread, x86_THREAD_STATE64,
                                             (thread_state_t)&state, &record->state_count);
    if (record->state_error != KERN_SUCCESS || record->state_count < expected) {
        record->result = CAPTURE_STATE_ERROR;
        return;
    }
    record->raw_pc = record->pc = (uintptr_t)state.__rip;
    record->fp = (uintptr_t)state.__rbp;
    record->sp = (uintptr_t)state.__rsp;
#endif
    record->result = CAPTURE_STACK;
    if (!record->pc) {
        record->walk = WALK_ZERO_PC;
        return;
    }
    record->frames[0].raw_pc = record->raw_pc;
    record->frames[0].pc = record->pc;
    record->frames[0].frame_pointer = 0;
    record->frame_count = 1;
    if (record->sp < session.stack_low || record->sp >= session.stack_high) {
        record->walk = WALK_STACK_RANGE;
        return;
    }
    uintptr_t fp = record->fp;
    while (record->frame_count < FRAME_CAPACITY) {
        if (!fp) {
            record->walk = WALK_END;
            return;
        }
        if (now_ns() - record->suspended_ns >= WALK_BUDGET_NS) {
            record->walk = WALK_BUDGET;
            return;
        }
        if (fp < record->sp || fp < session.stack_low ||
            fp > session.stack_high - 2 * sizeof(uintptr_t) || (fp & (sizeof(uintptr_t) - 1))) {
            record->failed_fp = fp;
            record->walk = WALK_INVALID_FRAME;
            return;
        }
        uintptr_t pair[2];
        record->read_size = 0;
        record->read_error = session.read_memory(session.task, (mach_vm_address_t)fp, sizeof(pair),
                                                   (mach_vm_address_t)(uintptr_t)pair, &record->read_size);
        if (record->read_error != KERN_SUCCESS) {
            record->failed_fp = fp;
            record->walk = WALK_READ_ERROR;
            return;
        }
        if (record->read_size != sizeof(pair)) {
            record->failed_fp = fp;
            record->walk = WALK_SHORT_READ;
            return;
        }
        uintptr_t pc = strip_code_pointer(pair[1]);
        if (!pc) {
            record->walk = WALK_END;
            return;
        }
        Frame *frame = &record->frames[record->frame_count++];
        frame->raw_pc = pair[1];
        frame->pc = pc;
        frame->frame_pointer = fp;
        uintptr_t next_fp = strip_frame_pointer(pair[0]);
        if (next_fp && next_fp <= fp) {
            record->failed_fp = next_fp;
            record->walk = WALK_INVALID_FRAME;
            return;
        }
        fp = next_fp;
    }
    record->walk = WALK_LIMIT;
}

static void capture_stack(StackRecord *record) {
    record->pre_suspend_cpu = sample_cpu(&watchdog_stats.cpu_stats);
    record->at_ns = record->pre_suspend_cpu.at_ns;
    if (atomic_load_explicit(&publication.stop, memory_order_acquire)) {
        record->result = CAPTURE_CANCELLED;
        return;
    }
    record->observed_version = atomic_load_explicit(&publication.publication, memory_order_seq_cst);
    if (record->observed_version != record->candidate.version) {
        record->result = CAPTURE_RACED;
        return;
    }
    record->suspend_begin_ns = now_ns();
    watchdog_stats.suspend_calls++;
    record->suspend_error = thread_suspend(session.main_thread);
    if (record->suspend_error != KERN_SUCCESS) {
        record->result = CAPTURE_SUSPEND_ERROR;
        watchdog_stats.suspend_errors++;
        watchdog_stats.last_suspend_error = record->suspend_error;
        return;
    }
    record->suspended_ns = now_ns();
    record->at_ns = record->suspended_ns;
    record->observed_version = atomic_load_explicit(&publication.publication, memory_order_seq_cst);
    // Main marks publication busy before measuring a beat or a context transition.
    if (record->observed_version != record->candidate.version ||
        atomic_load_explicit(&publication.stop, memory_order_acquire) ||
        !atomic_load_explicit(&publication.active, memory_order_acquire)) {
        record->result = CAPTURE_RACED;
    } else {
        record->accepted = true;
        capture_frames(record);
    }
    record->resume_begin_ns = now_ns();
    for (;;) {
        record->resume_attempts++;
        kern_return_t error = session.resume(session.main_thread);
        if (error == KERN_SUCCESS) break;
        if (!record->first_resume_error) record->first_resume_error = error;
        watchdog_stats.resume_errors++;
        watchdog_stats.last_resume_error = error;
        // No output or cleanup can safely precede termination if resume is impossible.
        if (record->resume_attempts == 3) session.exit_process(86);
    }
    record->resume_end_ns = now_ns();
    uint64_t envelope = record->resume_end_ns - record->suspend_begin_ns;
    watchdog_stats.suspend_envelope_total_ns += envelope;
    if (envelope > watchdog_stats.suspend_envelope_max_ns) watchdog_stats.suspend_envelope_max_ns = envelope;
}

static void *watchdog_main(void *unused) {
    (void)unused;
    watchdog_stats.cancel_disable_error = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    sigset_t blocked;
    sigfillset(&blocked);
    watchdog_stats.signal_mask_error = pthread_sigmask(SIG_SETMASK, &blocked, NULL);
    uint64_t poll_ticks = (uint64_t)(((__uint128_t)POLL_NS * session.timebase.denom +
                                     session.timebase.numer - 1) / session.timebase.numer);
    uint64_t deadline = mach_absolute_time() + poll_ticks;
    uint64_t last_interval = 0;
    uint64_t last_attempt_ns = 0;
    while (!atomic_load_explicit(&publication.stop, memory_order_acquire)) {
        Wake wake = {0};
        wake.wait_start_ns = now_ns();
        wake.due_ns = ticks_to_ns(deadline);
        wake.wait_error = mach_wait_until(deadline);
        uint64_t tick = mach_absolute_time();
        wake.at_ns = ticks_to_ns(tick);
        if (atomic_load_explicit(&publication.stop, memory_order_acquire)) break;
        wake.sequence = next_sequence();
        wake.missed_deadlines = tick > deadline ? (tick - deadline) / poll_ticks : 0;
        deadline += (wake.missed_deadlines + 1) * poll_ticks;
        wake.snapshot_result = read_snapshot(&wake.snapshot);
        wake.snapshot_at_ns = now_ns();
        watchdog_stats.wake_count++;
        watchdog_stats.missed_deadlines += wake.missed_deadlines;
        uint64_t lateness = positive_difference(wake.at_ns, wake.due_ns);
        uint64_t wait_from = wake.wait_start_ns > wake.due_ns ? wake.wait_start_ns : wake.due_ns;
        uint64_t overshoot = positive_difference(wake.at_ns, wait_from);
        uint64_t work_overdue = positive_difference(wake.wait_start_ns, wake.due_ns);
        watchdog_stats.wake_lateness_total_ns += lateness;
        if (lateness > watchdog_stats.wake_lateness_max_ns) {
            watchdog_stats.wake_lateness_max_ns = lateness;
            watchdog_stats.wake_lateness_max_at_ns = wake.at_ns;
        }
        if (overshoot > watchdog_stats.wait_overshoot_max_ns) watchdog_stats.wait_overshoot_max_ns = overshoot;
        if (work_overdue > watchdog_stats.work_overdue_max_ns) watchdog_stats.work_overdue_max_ns = work_overdue;
        if (wake.wait_error != KERN_SUCCESS) {
            watchdog_stats.wait_errors++;
            watchdog_stats.last_wait_error = wake.wait_error;
        }
        if (watchdog_stats.wake_stored < WAKE_CAPACITY) wakes[watchdog_stats.wake_stored++] = wake;
        else watchdog_stats.wake_dropped++;
        if (wake.snapshot_result == SNAPSHOT_BUSY) watchdog_stats.snapshot_busy++;
        if (wake.snapshot_result == SNAPSHOT_CHANGED) watchdog_stats.snapshot_changed++;
        if (wake.snapshot_result != SNAPSHOT_STABLE || !wake.snapshot.active) continue;
        if (last_interval != wake.snapshot.interval_sequence) {
            last_interval = wake.snapshot.interval_sequence;
            last_attempt_ns = 0;
        }
        if (wake.at_ns <= wake.snapshot.beat_at_ns || wake.at_ns - wake.snapshot.beat_at_ns <= GAP_NS ||
            (last_attempt_ns && wake.at_ns - last_attempt_ns < STACK_PERIOD_NS)) continue;
        last_attempt_ns = wake.at_ns;
        watchdog_stats.stack_count++;
        if (watchdog_stats.stack_stored == STACK_CAPACITY) {
            watchdog_stats.stack_dropped++;
            continue;
        }
        StackRecord *record = &stacks[watchdog_stats.stack_stored++];
        memset(record, 0, sizeof(*record));
        record->sequence = next_sequence();
        record->wake_sequence = wake.sequence;
        record->candidate = wake.snapshot;
        record->due_ns = wake.due_ns;
        record->wake_ns = wake.at_ns;
        record->wait_start_ns = wake.wait_start_ns;
        capture_stack(record);
        if (record->accepted) watchdog_stats.accepted_stacks++;
        if (record->result == CAPTURE_RACED) watchdog_stats.raced_stacks++;
        if (record->state_error != KERN_SUCCESS) {
            watchdog_stats.state_errors++;
            watchdog_stats.last_state_error = record->state_error;
        } else if (record->result == CAPTURE_STATE_ERROR) {
            watchdog_stats.short_states++;
        }
        if (record->read_error != KERN_SUCCESS) {
            watchdog_stats.read_errors++;
            watchdog_stats.last_read_error = record->read_error;
        }
        if (record->walk == WALK_SHORT_READ) watchdog_stats.short_reads++;
    }
    return NULL;
}

static void make_fixture_json(const char *fixture) {
    size_t length = fixture ? strnlen(fixture, FIXTURE_CAPACITY) : 0;
    session.fixture_truncated = length == FIXTURE_CAPACITY;
    if (length >= FIXTURE_CAPACITY) {
        length = FIXTURE_CAPACITY - 1;
        while (length && ((unsigned char)fixture[length] & 0xc0) == 0x80) length--;
    }
    if (length) memcpy(session.fixture, fixture, length);
    session.fixture[length] = 0;
    char *out = session.fixture_json;
    *out++ = '"';
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)session.fixture[i];
        if (c == '"' || c == '\\') {
            *out++ = '\\';
            *out++ = (char)c;
        } else if (c < 0x20) {
            *out++ = '\\'; *out++ = 'u'; *out++ = '0'; *out++ = '0';
            *out++ = hex[c >> 4]; *out++ = hex[c & 15];
        } else {
            *out++ = (char)c;
        }
    }
    *out++ = '"';
    *out = 0;
}

static void touch_storage(void) {
    if (storage_touched) return;
    memset(intervals, 0, sizeof(intervals));
    memset(overflow_gaps, 0, sizeof(overflow_gaps));
    memset(contexts, 0, sizeof(contexts));
    memset(wakes, 0, sizeof(wakes));
    memset(stacks, 0, sizeof(stacks));
    storage_touched = true;
}

void easl_gap_start(const char *fixture) {
    if (session.live) {
        session.lifecycle_errors++;
        return;
    }
    memset(&session, 0, sizeof(session));
    memset(&watchdog_stats, 0, sizeof(watchdog_stats));
    session.live = true;
    session.session_sequence = ++session_sequence;
    session.context = (Context){ .sequence = 1, .edit = -1, .phase = 0 };
    make_fixture_json(fixture);
    atomic_init(&publication.publication, 1);
    atomic_init(&publication.record_sequence, 0);
    atomic_init(&publication.interval_sequence, 0);
    atomic_init(&publication.beat_at_ns, 0);
    atomic_init(&publication.context_sequence, 0);
    atomic_init(&publication.context_at_ns, 0);
    atomic_init(&publication.edit, -1);
    atomic_init(&publication.phase, 0);
    atomic_init(&publication.active, 0);
    atomic_init(&publication.stop, 0);
    if (!pthread_main_np()) {
        session.start_result = START_NOT_MAIN;
        return;
    }
    session.timebase_error = mach_timebase_info(&session.timebase);
    if (session.timebase_error != KERN_SUCCESS || !session.timebase.numer || !session.timebase.denom) {
        session.start_result = START_CLOCK_ERROR;
        return;
    }
    session.start_ns = now_ns();
    session.main_thread = mach_thread_self();
    session.task = mach_task_self();
    session.stack_high = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t stack_size = pthread_get_stacksize_np(pthread_self());
    if (!session.stack_high || stack_size < 2 * sizeof(uintptr_t) || stack_size > session.stack_high) {
        session.start_result = START_STACK_BOUNDS_ERROR;
        return;
    }
    session.stack_low = session.stack_high - stack_size;
    // Resolve suspended-region calls before main can own a dyld or allocator lock.
    session.get_state = (StateFunction)dlsym(RTLD_DEFAULT, "thread_get_state");
    session.read_memory = (ReadFunction)dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite");
    session.resume = (ResumeFunction)dlsym(RTLD_DEFAULT, "thread_resume");
    session.exit_process = (ExitFunction)dlsym(RTLD_DEFAULT, "_exit");
    if (!session.get_state) session.missing_symbols |= 1;
    if (!session.read_memory) session.missing_symbols |= 2;
    if (!session.resume) session.missing_symbols |= 4;
    if (!session.exit_process) session.missing_symbols |= 8;
    if (session.missing_symbols) {
        session.start_result = START_SYMBOL_ERROR;
        return;
    }
    thread_state_data_t warm_state;
    mach_msg_type_number_t warm_count = THREAD_STATE_MAX;
#if defined(__arm64__)
    session.warm_state_error = session.get_state(session.main_thread, ARM_THREAD_STATE64, warm_state, &warm_count);
#else
    session.warm_state_error = session.get_state(session.main_thread, x86_THREAD_STATE64, warm_state, &warm_count);
#endif
    uint64_t source = UINT64_C(0x47504150524f4245);
    uint64_t destination = 0;
    session.warm_read_error = session.read_memory(session.task, (mach_vm_address_t)(uintptr_t)&source,
                                                  sizeof(source), (mach_vm_address_t)(uintptr_t)&destination,
                                                  &session.warm_read_size);
    if (session.warm_read_error != KERN_SUCCESS || session.warm_read_size != sizeof(source) || destination != source) {
        session.start_result = START_READ_ERROR;
        return;
    }
    touch_storage();
    session.interval_sequence = 1;
    session.context = (Context){ .sequence = 1, .edit = -1, .phase = 0 };
    session.enabled = true;
    session.create_error = pthread_create(&session.watchdog, NULL, watchdog_main, NULL);
    if (session.create_error) {
        session.enabled = false;
        session.start_result = START_PTHREAD_ERROR;
        return;
    }
    session.watchdog_created = true;
    session.beat_cpu = sample_cpu(&session.cpu_stats);
    session.context_cpu = session.beat_cpu;
    session.beat_context = session.context;
    session.start_ns = session.beat_cpu.at_ns;
    atomic_store_explicit(&publication.active, 1, memory_order_relaxed);
    publish();
}

static void account_main_probe(uint64_t begin_ns) {
    uint64_t duration = now_ns() - begin_ns;
    session.main_probe_wall_ns += duration;
    if (duration > session.main_probe_max_ns) session.main_probe_max_ns = duration;
}

void easl_gap_beat(void) {
    if (!session.live || !session.enabled) return;
    atomic_fetch_add_explicit(&publication.publication, 1, memory_order_seq_cst);
    CPU cpu = sample_cpu(&session.cpu_stats);
    Interval record = {
        .sequence = next_sequence(),
        .interval_sequence = session.interval_sequence,
        .start_context = session.beat_context,
        .end_context = session.context,
        .start = session.beat_cpu,
        .end = cpu
    };
    session.heartbeat_count++;
    bool gap = cpu.at_ns - session.beat_cpu.at_ns > GAP_NS;
    if (gap) session.gap_count++;
    if (session.interval_stored < INTERVAL_CAPACITY) {
        intervals[session.interval_stored++] = record;
    } else {
        session.interval_dropped++;
        if (gap) {
            if (session.overflow_gap_stored < OVERFLOW_GAP_CAPACITY) overflow_gaps[session.overflow_gap_stored++] = record;
            else session.gap_dropped++;
        }
    }
    session.interval_sequence++;
    session.beat_cpu = cpu;
    session.beat_context = session.context;
    publish();
    account_main_probe(cpu.at_ns);
}

static void close_context(CPU cpu, Context next, bool stopping) {
    ContextRecord record = {
        .sequence = next_sequence(),
        .interval_sequence = session.interval_sequence,
        .closed = session.context,
        .next = next,
        .start = session.context_cpu,
        .end = cpu,
        .stopping = stopping
    };
    session.context_count++;
    if (session.context_stored < CONTEXT_CAPACITY) contexts[session.context_stored++] = record;
    else session.context_dropped++;
}

void easl_gap_context(int edit, int phase) {
    if (!session.live || !session.enabled) return;
    atomic_fetch_add_explicit(&publication.publication, 1, memory_order_seq_cst);
    CPU cpu = sample_cpu(&session.cpu_stats);
    Context next = { .sequence = session.context.sequence + 1, .edit = edit, .phase = phase };
    close_context(cpu, next, false);
    session.context = next;
    session.context_cpu = cpu;
    publish();
    account_main_probe(cpu.at_ns);
}

static void emit_json_string(const char *value) {
    if (!value) {
        fputs("null", stdout);
        return;
    }
    fputc('"', stdout);
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        if (*p == '"' || *p == '\\') {
            fputc('\\', stdout);
            fputc(*p, stdout);
        } else if (*p < 0x20) {
            fprintf(stdout, "\\u%04x", *p);
        } else {
            fputc(*p, stdout);
        }
    }
    fputc('"', stdout);
}

static void emit_header(const char *event, uint64_t sequence, Context context, uint64_t at_ns) {
    fputs("{\"event\":", stdout);
    emit_json_string(event);
    fputs(",\"fixture\":", stdout);
    fputs(session.fixture_json, stdout);
    fprintf(stdout, ",\"sessionSeq\":%" PRIu64 ",\"sequence\":%" PRIu64
                    ",\"edit\":%d,\"phase\":%d,\"atNs\":",
            session.session_sequence, sequence, context.edit, context.phase);
    if (session.timebase.numer && session.timebase.denom) fprintf(stdout, "%" PRIu64, at_ns);
    else fputs("null", stdout);
}

static const char *run_state_name(int state) {
    switch (state) {
        case TH_STATE_RUNNING: return "running-or-runnable";
        case TH_STATE_STOPPED: return "stopped";
        case TH_STATE_WAITING: return "waiting";
        case TH_STATE_UNINTERRUPTIBLE: return "uninterruptible";
        case TH_STATE_HALTED: return "halted";
        default: return "unknown";
    }
}

static void emit_cpu(const CPU *cpu) {
    fprintf(stdout, "{\"sampleStartNs\":%" PRIu64 ",\"sampleEndNs\":%" PRIu64
                    ",\"apiError\":%d,\"returnedCount\":%u,\"valid\":%s",
            cpu->at_ns, cpu->end_ns, cpu->error, cpu->returned_count, cpu->valid ? "true" : "false");
    if (cpu->valid) {
        fprintf(stdout, ",\"userNs\":%" PRIu64 ",\"systemNs\":%" PRIu64 ",\"totalNs\":%" PRIu64
                        ",\"runState\":%d,\"runStateName\":\"%s\",\"suspendCount\":%d"
                        ",\"flags\":%d,\"usagePerThousand\":%d}",
                cpu->user_ns, cpu->system_ns, cpu->user_ns + cpu->system_ns, cpu->run_state,
                run_state_name(cpu->run_state), cpu->suspend_count, cpu->flags, cpu->usage);
    } else {
        fputs(",\"userNs\":null,\"systemNs\":null,\"totalNs\":null,\"runState\":null,"
              "\"runStateName\":null,\"suspendCount\":null,\"flags\":null,\"usagePerThousand\":null}", stdout);
    }
}

static void emit_cpu_delta(const CPU *start, const CPU *end) {
    if (start->valid && end->valid && end->user_ns >= start->user_ns && end->system_ns >= start->system_ns) {
        uint64_t user = end->user_ns - start->user_ns;
        uint64_t system = end->system_ns - start->system_ns;
        fprintf(stdout, ",\"userCpuDeltaNs\":%" PRIu64 ",\"systemCpuDeltaNs\":%" PRIu64
                        ",\"cpuDeltaNs\":%" PRIu64, user, system, user + system);
    } else {
        fputs(",\"userCpuDeltaNs\":null,\"systemCpuDeltaNs\":null,\"cpuDeltaNs\":null", stdout);
    }
}

static void emit_interval(const Interval *record, const char *event) {
    emit_header(event, record->sequence, record->end_context, record->end.at_ns);
    fprintf(stdout, ",\"intervalSeq\":%" PRIu64 ",\"startNs\":%" PRIu64 ",\"endNs\":%" PRIu64
                    ",\"wallNs\":%" PRIu64 ",\"startContextSeq\":%" PRIu64
                    ",\"startEdit\":%d,\"startPhase\":%d,\"endContextSeq\":%" PRIu64
                    ",\"endEdit\":%d,\"endPhase\":%d,\"startCPU\":",
            record->interval_sequence, record->start.at_ns, record->end.at_ns,
            record->end.at_ns - record->start.at_ns, record->start_context.sequence,
            record->start_context.edit, record->start_context.phase, record->end_context.sequence,
            record->end_context.edit, record->end_context.phase);
    emit_cpu(&record->start);
    fputs(",\"endCPU\":", stdout);
    emit_cpu(&record->end);
    emit_cpu_delta(&record->start, &record->end);
    fputs("}\n", stdout);
}

static void emit_context(const ContextRecord *record) {
    emit_header("gap-context", record->sequence, record->closed, record->end.at_ns);
    fprintf(stdout, ",\"intervalSeq\":%" PRIu64 ",\"contextSeq\":%" PRIu64
                    ",\"startNs\":%" PRIu64 ",\"endNs\":%" PRIu64 ",\"wallNs\":%" PRIu64
                    ",\"reason\":\"%s\",\"nextContextSeq\":%" PRIu64
                    ",\"nextEdit\":%d,\"nextPhase\":%d,\"startCPU\":",
            record->interval_sequence, record->closed.sequence, record->start.at_ns, record->end.at_ns,
            record->end.at_ns - record->start.at_ns, record->stopping ? "stop" : "transition",
            record->next.sequence, record->next.edit, record->next.phase);
    emit_cpu(&record->start);
    fputs(",\"endCPU\":", stdout);
    emit_cpu(&record->end);
    emit_cpu_delta(&record->start, &record->end);
    fputs("}\n", stdout);
}

static void emit_wake(const Wake *wake) {
    bool known = wake->snapshot_result == SNAPSHOT_STABLE && wake->snapshot.active;
    Context context = known ? wake->snapshot.context : (Context){ .edit = -1, .phase = -1 };
    emit_header("watchdog-wake", wake->sequence, context, wake->at_ns);
    fprintf(stdout, ",\"snapshotAtNs\":%" PRIu64, wake->snapshot_at_ns);
    uint64_t wait_from = wake->wait_start_ns > wake->due_ns ? wake->wait_start_ns : wake->due_ns;
    fprintf(stdout, ",\"dueNs\":%" PRIu64 ",\"waitStartNs\":%" PRIu64
                    ",\"deadlineLatenessNs\":%" PRIu64 ",\"waitOvershootNs\":%" PRIu64
                    ",\"workOverdueNs\":%" PRIu64 ",\"missedDeadlines\":%" PRIu64
                    ",\"waitError\":%d,\"publicationStatus\":\"%s\",\"intervalSeq\":",
            wake->due_ns, wake->wait_start_ns, positive_difference(wake->at_ns, wake->due_ns),
            positive_difference(wake->at_ns, wait_from), positive_difference(wake->wait_start_ns, wake->due_ns),
            wake->missed_deadlines, wake->wait_error,
            wake->snapshot_result == SNAPSHOT_STABLE ? "stable" :
            wake->snapshot_result == SNAPSHOT_BUSY ? "busy" : "changed");
    if (known) {
        fprintf(stdout, "%" PRIu64 ",\"contextSeq\":%" PRIu64 ",\"beatAtNs\":%" PRIu64
                        ",\"beatAgeNs\":%" PRIu64,
                wake->snapshot.interval_sequence, wake->snapshot.context.sequence, wake->snapshot.beat_at_ns,
                positive_difference(wake->at_ns, wake->snapshot.beat_at_ns));
    } else {
        fputs("null,\"contextSeq\":null,\"beatAtNs\":null,\"beatAgeNs\":null", stdout);
    }
    fputs("}\n", stdout);
}

static const char *capture_name(CaptureResult result) {
    switch (result) {
        case CAPTURE_PENDING: return "pending";
        case CAPTURE_CANCELLED: return "cancelled";
        case CAPTURE_RACED: return "publication-raced";
        case CAPTURE_SUSPEND_ERROR: return "suspend-error";
        case CAPTURE_STATE_ERROR: return "state-error";
        case CAPTURE_STACK: return "captured";
    }
    return "unknown";
}

static const char *walk_name(WalkResult result) {
    switch (result) {
        case WALK_NOT_STARTED: return "not-started";
        case WALK_END: return "end";
        case WALK_LIMIT: return "frame-limit";
        case WALK_BUDGET: return "time-budget";
        case WALK_STACK_RANGE: return "sp-outside-main-stack";
        case WALK_INVALID_FRAME: return "invalid-frame-chain";
        case WALK_READ_ERROR: return "read-error";
        case WALK_SHORT_READ: return "short-read";
        case WALK_ZERO_PC: return "zero-pc";
    }
    return "unknown";
}

static void emit_frame(const Frame *frame, unsigned index) {
    uintptr_t lookup = frame->pc - (index && frame->pc ? 1 : 0);
    Dl_info info;
    memset(&info, 0, sizeof(info));
    int found = dladdr((const void *)lookup, &info);
    fprintf(stdout, "{\"kind\":\"%s\",\"rawPc\":\"0x%" PRIxPTR "\",\"pc\":\"0x%" PRIxPTR
                    "\",\"lookupPc\":\"0x%" PRIxPTR "\",\"framePointer\":\"0x%" PRIxPTR "\",\"symbol\":",
            index ? "return-address" : "instruction", frame->raw_pc, frame->pc, lookup, frame->frame_pointer);
    emit_json_string(found ? info.dli_sname : NULL);
    fputs(",\"symbolAddress\":", stdout);
    if (found && info.dli_saddr) fprintf(stdout, "\"0x%" PRIxPTR "\"", (uintptr_t)info.dli_saddr);
    else fputs("null", stdout);
    fputs(",\"symbolOffset\":", stdout);
    if (found && info.dli_saddr && lookup >= (uintptr_t)info.dli_saddr) {
        fprintf(stdout, "%" PRIuPTR, lookup - (uintptr_t)info.dli_saddr);
    } else fputs("null", stdout);
    fputs(",\"image\":", stdout);
    emit_json_string(found ? info.dli_fname : NULL);
    fputs(",\"imageAddress\":", stdout);
    if (found && info.dli_fbase) fprintf(stdout, "\"0x%" PRIxPTR "\"", (uintptr_t)info.dli_fbase);
    else fputs("null", stdout);
    fputs(",\"imageOffset\":", stdout);
    if (found && info.dli_fbase && lookup >= (uintptr_t)info.dli_fbase) {
        fprintf(stdout, "%" PRIuPTR, lookup - (uintptr_t)info.dli_fbase);
    } else fputs("null", stdout);
    fputc('}', stdout);
}

static void emit_stack(const StackRecord *record) {
    Context context = record->accepted ? record->candidate.context : (Context){ .edit = -1, .phase = -1 };
    emit_header("watchdog-stack", record->sequence, context, record->at_ns);
    fprintf(stdout, ",\"wakeSequence\":%" PRIu64 ",\"accepted\":%s,\"result\":\"%s\",\"walkEnd\":\"%s\""
                    ",\"candidateIntervalSeq\":%" PRIu64 ",\"candidateContextSeq\":%" PRIu64
                    ",\"candidateEdit\":%d,\"candidatePhase\":%d,\"intervalSeq\":",
            record->wake_sequence, record->accepted ? "true" : "false", capture_name(record->result),
            walk_name(record->walk), record->candidate.interval_sequence, record->candidate.context.sequence,
            record->candidate.context.edit, record->candidate.context.phase);
    if (record->accepted) fprintf(stdout, "%" PRIu64, record->candidate.interval_sequence);
    else fputs("null", stdout);
    uint64_t wait_from = record->wait_start_ns > record->due_ns ? record->wait_start_ns : record->due_ns;
    fprintf(stdout, ",\"contextSeq\":%" PRIu64 ",\"contextAtNs\":%" PRIu64
                    ",\"candidateVersion\":%" PRIu64 ",\"observedVersion\":%" PRIu64
                    ",\"beatAtNs\":%" PRIu64 ",\"beatAgeNs\":%" PRIu64
                    ",\"dueNs\":%" PRIu64 ",\"wakeNs\":%" PRIu64 ",\"waitStartNs\":%" PRIu64
                    ",\"deadlineLatenessNs\":%" PRIu64 ",\"waitOvershootNs\":%" PRIu64
                    ",\"suspendBeginNs\":%" PRIu64 ",\"suspendedNs\":%" PRIu64
                    ",\"resumeBeginNs\":%" PRIu64 ",\"resumeEndNs\":%" PRIu64
                    ",\"suspendEnvelopeNs\":%" PRIu64 ",\"suspendError\":%d,\"stateError\":%d"
                    ",\"stateCount\":%u,\"readError\":%d,\"readSize\":%" PRIu64
                    ",\"firstResumeError\":%d,\"resumeAttempts\":%u,\"preSuspendCPU\":",
            record->candidate.context.sequence, record->candidate.context_at_ns,
            record->candidate.version, record->observed_version, record->candidate.beat_at_ns,
            positive_difference(record->at_ns, record->candidate.beat_at_ns), record->due_ns,
            record->wake_ns, record->wait_start_ns, positive_difference(record->wake_ns, record->due_ns),
            positive_difference(record->wake_ns, wait_from), record->suspend_begin_ns, record->suspended_ns,
            record->resume_begin_ns, record->resume_end_ns,
            record->resume_end_ns ? record->resume_end_ns - record->suspend_begin_ns : 0,
            record->suspend_error, record->state_error, record->state_count, record->read_error,
            (uint64_t)record->read_size, record->first_resume_error, record->resume_attempts);
    emit_cpu(&record->pre_suspend_cpu);
    fprintf(stdout, ",\"registers\":{\"rawPc\":\"0x%" PRIxPTR "\",\"rawLr\":\"0x%" PRIxPTR
                    "\",\"pc\":\"0x%" PRIxPTR "\",\"lr\":\"0x%" PRIxPTR
                    "\",\"sp\":\"0x%" PRIxPTR "\",\"fp\":\"0x%" PRIxPTR
                    "\"},\"failedFramePointer\":\"0x%" PRIxPTR "\",\"frameCount\":%u,\"frames\":[",
            record->raw_pc, record->raw_lr, record->pc, record->lr, record->sp, record->fp,
            record->failed_fp, record->frame_count);
    for (unsigned i = 0; i < record->frame_count; i++) {
        if (i) fputc(',', stdout);
        emit_frame(&record->frames[i], i);
    }
    fputs("]}\n", stdout);
}

static void emit_cpu_stats(const CPUStats *stats) {
    fprintf(stdout, "{\"calls\":%" PRIu64 ",\"apiErrors\":%" PRIu64 ",\"shortResults\":%" PRIu64
                    ",\"lastError\":%d,\"wallNs\":%" PRIu64 "}",
            stats->calls, stats->api_errors, stats->short_results, stats->last_error, stats->wall_ns);
}

static const char *start_name(StartResult result) {
    switch (result) {
        case START_OK: return "ok";
        case START_NOT_MAIN: return "start-not-on-main-thread";
        case START_CLOCK_ERROR: return "clock-error";
        case START_SYMBOL_ERROR: return "required-mach-symbol-unavailable";
        case START_STACK_BOUNDS_ERROR: return "main-stack-bounds-unavailable";
        case START_READ_ERROR: return "safe-read-unavailable";
        case START_PTHREAD_ERROR: return "pthread-create-error";
    }
    return "unknown";
}

static void emit_summary(void) {
    emit_header("instrumentation-summary", next_sequence(), session.context, session.stop_ns);
    fprintf(stdout, ",\"watchdogCreated\":%s", session.watchdog_created ? "true" : "false");
    fprintf(stdout, ",\"enabled\":%s,\"startResult\":\"%s\",\"clock\":\"mach_absolute_time\""
                    ",\"timebaseNumer\":%u,\"timebaseDenom\":%u,\"timebaseError\":%d"
                    ",\"startNs\":%" PRIu64 ",\"stopNs\":%" PRIu64 ",\"joinedNs\":%" PRIu64
                    ",\"gapThresholdNs\":%" PRIu64 ",\"pollPeriodNs\":%" PRIu64
                    ",\"stackPeriodNs\":%" PRIu64 ",\"walkBudgetNs\":%" PRIu64
                    ",\"frameCapacity\":%d,\"intervalCapacity\":%d,\"overflowGapCapacity\":%d"
                    ",\"contextCapacity\":%d,\"wakeCapacity\":%d,\"stackCapacity\":%d"
                    ",\"fixtureTruncated\":%s,\"mainThreadPort\":%u,\"mainStackLow\":\"0x%" PRIxPTR
                    "\",\"mainStackHigh\":\"0x%" PRIxPTR "\",\"missingSymbolMask\":%u"
                    ",\"warmStateError\":%d,\"warmReadError\":%d,\"warmReadSize\":%" PRIu64
                    ",\"createError\":%d,\"joinError\":%d,\"deallocateError\":%d"
                    ",\"watchdogJoined\":%s,\"cancelDisableError\":%d,\"signalMaskError\":%d"
                    ",\"heartbeatIntervals\":%" PRIu64 ",\"heartbeatIntervalsStored\":%zu"
                    ",\"heartbeatIntervalsDropped\":%" PRIu64 ",\"gaps\":%" PRIu64
                    ",\"overflowGapsStored\":%zu,\"gapsDropped\":%" PRIu64
                    ",\"contextRecords\":%" PRIu64 ",\"contextRecordsStored\":%zu"
                    ",\"contextRecordsDropped\":%" PRIu64 ",\"lifecycleErrors\":%" PRIu64
                    ",\"mainProbeWallNsTotal\":%" PRIu64 ",\"mainProbeWallNsMax\":%" PRIu64
                    ",\"cpuResolutionNs\":1000,\"cpuDeltasIncludeProbe\":true"
                    ",\"runningStateMeansOnCoreOrRunnable\":true,\"mainCPU\":",
            session.enabled ? "true" : "false", start_name(session.start_result),
            session.timebase.numer, session.timebase.denom, session.timebase_error,
            session.start_ns, session.stop_ns, session.joined_ns, GAP_NS, POLL_NS, STACK_PERIOD_NS, WALK_BUDGET_NS,
            FRAME_CAPACITY, INTERVAL_CAPACITY, OVERFLOW_GAP_CAPACITY, CONTEXT_CAPACITY, WAKE_CAPACITY, STACK_CAPACITY,
            session.fixture_truncated ? "true" : "false", session.main_thread, session.stack_low, session.stack_high,
            session.missing_symbols, session.warm_state_error, session.warm_read_error,
            (uint64_t)session.warm_read_size, session.create_error, session.join_error, session.deallocate_error,
            session.watchdog_created && !session.join_error ? "true" : "false",
            watchdog_stats.cancel_disable_error, watchdog_stats.signal_mask_error,
            session.heartbeat_count, session.interval_stored, session.interval_dropped, session.gap_count,
            session.overflow_gap_stored, session.gap_dropped, session.context_count, session.context_stored,
            session.context_dropped, session.lifecycle_errors, session.main_probe_wall_ns, session.main_probe_max_ns);
    emit_cpu_stats(&session.cpu_stats);
    fputs(",\"watchdogCPU\":", stdout);
    emit_cpu_stats(&watchdog_stats.cpu_stats);
    fprintf(stdout, ",\"watchdogWakes\":%" PRIu64 ",\"watchdogWakesStored\":%zu"
                    ",\"watchdogWakesDropped\":%" PRIu64 ",\"deadlineLatenessNsTotal\":%" PRIu64
                    ",\"deadlineLatenessNsMax\":%" PRIu64 ",\"deadlineLatenessMaxAtNs\":%" PRIu64
                    ",\"waitOvershootNsMax\":%" PRIu64 ",\"workOverdueNsMax\":%" PRIu64
                    ",\"missedDeadlines\":%" PRIu64 ",\"waitErrors\":%" PRIu64 ",\"lastWaitError\":%d"
                    ",\"publicationBusyPolls\":%" PRIu64 ",\"publicationChangedPolls\":%" PRIu64
                    ",\"stackAttempts\":%" PRIu64 ",\"stackRecordsStored\":%zu"
                    ",\"stackRecordsDropped\":%" PRIu64 ",\"acceptedStacks\":%" PRIu64
                    ",\"racedStacks\":%" PRIu64 ",\"suspendCalls\":%" PRIu64
                    ",\"suspendErrors\":%" PRIu64 ",\"lastSuspendError\":%d"
                    ",\"stateErrors\":%" PRIu64 ",\"lastStateError\":%d,\"shortStates\":%" PRIu64
                    ",\"readErrors\":%" PRIu64 ",\"lastReadError\":%d,\"shortReads\":%" PRIu64
                    ",\"resumeErrors\":%" PRIu64 ",\"lastResumeError\":%d"
                    ",\"suspendEnvelopeNsTotal\":%" PRIu64 ",\"suspendEnvelopeNsMax\":%" PRIu64 "}\n",
            watchdog_stats.wake_count, watchdog_stats.wake_stored, watchdog_stats.wake_dropped,
            watchdog_stats.wake_lateness_total_ns, watchdog_stats.wake_lateness_max_ns,
            watchdog_stats.wake_lateness_max_at_ns, watchdog_stats.wait_overshoot_max_ns,
            watchdog_stats.work_overdue_max_ns, watchdog_stats.missed_deadlines,
            watchdog_stats.wait_errors, watchdog_stats.last_wait_error, watchdog_stats.snapshot_busy,
            watchdog_stats.snapshot_changed, watchdog_stats.stack_count, watchdog_stats.stack_stored,
            watchdog_stats.stack_dropped, watchdog_stats.accepted_stacks, watchdog_stats.raced_stacks,
            watchdog_stats.suspend_calls, watchdog_stats.suspend_errors, watchdog_stats.last_suspend_error,
            watchdog_stats.state_errors, watchdog_stats.last_state_error, watchdog_stats.short_states,
            watchdog_stats.read_errors, watchdog_stats.last_read_error, watchdog_stats.short_reads,
            watchdog_stats.resume_errors, watchdog_stats.last_resume_error,
            watchdog_stats.suspend_envelope_total_ns, watchdog_stats.suspend_envelope_max_ns);
}

void easl_gap_stop(void) {
    if (!session.live) return;
    if (session.enabled) {
        atomic_fetch_add_explicit(&publication.publication, 1, memory_order_seq_cst);
        atomic_store_explicit(&publication.active, 0, memory_order_relaxed);
        atomic_store_explicit(&publication.stop, 1, memory_order_release);
        CPU cpu = sample_cpu(&session.cpu_stats);
        session.stop_ns = cpu.at_ns;
        close_context(cpu, session.context, true);
        publish();
    } else {
        atomic_store_explicit(&publication.stop, 1, memory_order_release);
        if (session.timebase.numer && session.timebase.denom) session.stop_ns = now_ns();
    }
    if (session.watchdog_created) {
        session.join_error = pthread_join(session.watchdog, NULL);
        // Storage and the main thread right must outlive the watchdog, even on join failure.
        if (session.join_error) session.exit_process(87);
    }
    if (session.timebase.numer && session.timebase.denom) session.joined_ns = now_ns();
    if (session.main_thread) session.deallocate_error = mach_port_deallocate(session.task, session.main_thread);
    for (size_t i = 0; i < session.interval_stored; i++) {
        emit_interval(&intervals[i], "heartbeat-interval");
        if (intervals[i].end.at_ns - intervals[i].start.at_ns > GAP_NS) emit_interval(&intervals[i], "gap");
    }
    for (size_t i = 0; i < session.overflow_gap_stored; i++) emit_interval(&overflow_gaps[i], "gap");
    for (size_t i = 0; i < session.context_stored; i++) emit_context(&contexts[i]);
    for (size_t i = 0; i < watchdog_stats.wake_stored; i++) emit_wake(&wakes[i]);
    for (size_t i = 0; i < watchdog_stats.stack_stored; i++) emit_stack(&stacks[i]);
    emit_summary();
    fflush(stdout);
    session.live = false;
}

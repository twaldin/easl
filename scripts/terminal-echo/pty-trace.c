#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define DYLD_INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { \
        const void *replacement; const void *original; \
    } interpose_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

/* The zmx daemon owns one master and runs its PTY IO on one event-loop thread. */
enum event_kind { WRITE_CALL, WRITE_KEY, READ_CALL, READ_MARKER, TRACE_ERROR, CLOSED, EXITED };
enum trace_error { BAD_INPUT = 1, BAD_MARKER = 2, INCOMPLETE = 3 };
struct event {
    uint64_t enter, returned, offset;
    size_t requested;
    ssize_t result;
    unsigned seq;
    int error;
    enum event_kind kind;
};
#define EVENT_CAPACITY 16384
static struct {
    int enabled, master, log;
    pid_t pid;
    mach_timebase_info_data_t timebase;
    char path[1024];
    uint64_t input_offset, output_offset;
    unsigned input_seq, output_seq, expected;
    size_t count, dropped;
    size_t prefix_pos;
    unsigned marker_seq, marker_digits;
    struct event events[EVENT_CAPACITY];
} trace = { .master = -1, .log = -1 };
static const unsigned char marker_prefix[] = "\033]777;easl-echo;";

static double milliseconds(uint64_t ticks) {
    return (double)ticks * (double)trace.timebase.numer /
           (double)trace.timebase.denom / 1000000.0;
}

static void log_line(const char *line, size_t length) {
    while (length) {
        ssize_t n = write(trace.log, line, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(74);
        line += n;
        length -= (size_t)n;
    }
}

static void record(enum event_kind kind, uint64_t enter, uint64_t returned,
                   uint64_t offset, size_t requested, ssize_t result,
                   unsigned seq, int error) {
    if (trace.count == EVENT_CAPACITY) {
        ++trace.dropped;
        return;
    }
    trace.events[trace.count++] = (struct event){
        .enter = enter, .returned = returned, .offset = offset,
        .requested = requested, .result = result, .seq = seq,
        .error = error, .kind = kind
    };
}

static void flush_trace(void) {
    if (trace.log < 0) return;
    static const char *const stages[] = {
        "host_pty_write_call", "host_pty_write", "host_output_read_call",
        "host_output_read", "host_trace_error", "host_pty_closed", "host_process_exit"
    };
    char line[768];
    for (size_t i = 0; i < trace.count; ++i) {
        const struct event *e = &trace.events[i];
        int n = snprintf(line, sizeof(line),
            "{\"stage\":\"%s\",\"ts_ms\":%.9f,\"enter_ms\":%.9f,"
            "\"return_ms\":%.9f,\"pid\":%d,\"fd\":%d,\"seq\":%u,"
            "\"bytes\":%zu,\"offset\":%" PRIu64 ",\"requested\":%zu,"
            "\"result\":%zd,\"error\":%d,\"marker_start_offset\":%" PRIu64 "}\n",
            stages[e->kind], milliseconds(e->returned), milliseconds(e->enter),
            milliseconds(e->returned), trace.pid, trace.master, e->seq,
            e->result > 0 ? (size_t)e->result : 0, e->offset,
            e->requested, e->result, e->error,
            e->kind == READ_MARKER ? e->offset - e->requested : UINT64_C(0));
        if (n < 0 || (size_t)n >= sizeof(line)) _exit(74);
        log_line(line, (size_t)n);
    }
    int n = snprintf(line, sizeof(line),
        "{\"stage\":\"host_trace_summary\",\"ts_ms\":%.9f,\"pid\":%d,"
        "\"input_keys\":%u,\"output_markers\":%u,\"input_bytes\":%" PRIu64
        ",\"output_bytes\":%" PRIu64 ",\"dropped\":%zu}\n",
        milliseconds(mach_absolute_time()), trace.pid, trace.input_seq,
        trace.output_seq, trace.input_offset, trace.output_offset, trace.dropped);
    if (n < 0 || (size_t)n >= sizeof(line)) _exit(74);
    log_line(line, (size_t)n);
    int fd = trace.log;
    trace.log = -1;
    close(fd);
}

__attribute__((constructor)) static void initialize(void) {
    const char *path = getenv("EASL_PTY_TRACE_PATH");
    const char *program = getprogname();
    if (!program || strcmp(program, "zmx") || !path || path[0] != '/') return;
    size_t length = strlen(path);
    if (length >= sizeof(trace.path)) return;
    memcpy(trace.path, path, length + 1);
    trace.expected = getenv("EASL_PTY_TRACE_BURST") ? 1 : 100;
    if (mach_timebase_info(&trace.timebase) != KERN_SUCCESS || !trace.timebase.denom)
        return;
    trace.enabled = 1;
}

static pid_t traced_forkpty(int *master, char *name, struct termios *term,
                           struct winsize *size) {
    if (trace.enabled) {
        /* daemonize() already closed inherited FDs 3..63 before forkpty(). */
        trace.log = open(trace.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (trace.log < 0) return -1;
        struct stat st;
        if (fstat(trace.log, &st) || !S_ISREG(st.st_mode) ||
            st.st_uid != getuid() || st.st_nlink != 1) {
            close(trace.log);
            trace.log = -1;
            errno = EACCES;
            return -1;
        }
    }
    pid_t pid = forkpty(master, name, term, size);
    int saved_errno = errno;
    if (!trace.enabled) return pid;
    if (pid == 0) {
        trace.enabled = 0;
        trace.master = -1;
        close(trace.log);
        trace.log = -1;
        unsetenv("DYLD_INSERT_LIBRARIES");
        unsetenv("EASL_PTY_TRACE_PATH");
    } else if (pid < 0) {
        close(trace.log);
        trace.log = -1;
    } else {
        trace.master = *master;
        trace.pid = getpid();
        char line[512];
        int n = snprintf(line, sizeof(line),
            "{\"stage\":\"host_pty_tracked\",\"ts_ms\":%.9f,\"pid\":%d,"
            "\"fd\":%d,\"child_pid\":%d,\"clock\":\"mach_absolute_time\","
            "\"timebase_numer\":%u,\"timebase_denom\":%u}\n",
            milliseconds(mach_absolute_time()), trace.pid, trace.master, pid,
            trace.timebase.numer, trace.timebase.denom);
        if (n < 0 || (size_t)n >= sizeof(line)) _exit(74);
        log_line(line, (size_t)n);
    }
    errno = saved_errno;
    return pid;
}

static ssize_t traced_write(int fd, const void *buffer, size_t count) {
    if (fd != trace.master || trace.log < 0) return write(fd, buffer, count);
    uint64_t enter = mach_absolute_time();
    ssize_t n = write(fd, buffer, count);
    int saved_errno = errno;
    uint64_t returned = mach_absolute_time();
    record(WRITE_CALL, enter, returned, trace.input_offset, count, n, 0,
           n < 0 ? saved_errno : 0);
    if (n > 0) {
        const unsigned char *bytes = buffer;
        for (ssize_t i = 0; i < n; ++i) {
            ++trace.input_seq;
            ++trace.input_offset;
            enum event_kind kind = bytes[i] == 'a' && trace.input_seq <= 100 ?
                                   WRITE_KEY : TRACE_ERROR;
            record(kind, enter, returned, trace.input_offset, 1, 1,
                   trace.input_seq, kind == TRACE_ERROR ? BAD_INPUT : 0);
        }
    }
    errno = saved_errno;
    return n;
}

static void parse_output(const unsigned char *bytes, size_t count,
                         uint64_t enter, uint64_t returned) {
    const size_t prefix_length = sizeof(marker_prefix) - 1;
    for (size_t i = 0; i < count; ++i) {
        unsigned char byte = bytes[i];
        if (trace.prefix_pos < prefix_length) {
            if (byte == marker_prefix[trace.prefix_pos]) {
                ++trace.prefix_pos;
                if (trace.prefix_pos == prefix_length) {
                    trace.marker_seq = 0;
                    trace.marker_digits = 0;
                }
            } else {
                trace.prefix_pos = byte == marker_prefix[0] ? 1 : 0;
            }
            continue;
        }
        if (byte >= '0' && byte <= '9' && trace.marker_digits < 3) {
            trace.marker_seq = trace.marker_seq * 10 + byte - '0';
            ++trace.marker_digits;
            continue;
        }
        if (byte == '\a' && trace.marker_digits) {
            unsigned seq = trace.marker_seq;
            int valid = seq >= 1 && seq <= 100 && seq == trace.output_seq + 1;
            record(valid ? READ_MARKER : TRACE_ERROR, enter, returned,
                   trace.output_offset + i + 1, prefix_length + trace.marker_digits + 1,
                   0, seq, valid ? 0 : BAD_MARKER);
            if (valid) trace.output_seq = seq;
        }
        trace.prefix_pos = byte == marker_prefix[0] ? 1 : 0;
    }
}

static ssize_t traced_read(int fd, void *buffer, size_t count) {
    if (fd != trace.master || trace.log < 0) return read(fd, buffer, count);
    uint64_t enter = mach_absolute_time();
    ssize_t n = read(fd, buffer, count);
    int saved_errno = errno;
    uint64_t returned = mach_absolute_time();
    record(READ_CALL, enter, returned, trace.output_offset, count, n, 0,
           n < 0 ? saved_errno : 0);
    if (n > 0) {
        parse_output(buffer, (size_t)n, enter, returned);
        trace.output_offset += (uint64_t)n;
    }
    errno = saved_errno;
    return n;
}

static int traced_close(int fd) {
    if (fd != trace.master || trace.log < 0) return close(fd);
    uint64_t enter = mach_absolute_time();
    int result = close(fd);
    int saved_errno = errno;
    uint64_t returned = mach_absolute_time();
    record(CLOSED, enter, returned, 0, 0, result, 0, result < 0 ? saved_errno : 0);
    if (trace.input_seq != trace.expected || trace.output_seq != trace.expected)
        record(TRACE_ERROR, returned, returned, 0, 0, 0, 0, INCOMPLETE);
    flush_trace();
    trace.master = -1;
    errno = saved_errno;
    return result;
}

__attribute__((destructor)) static void finalize(void) {
    if (trace.log >= 0) {
        uint64_t now = mach_absolute_time();
        if (trace.input_seq != trace.expected || trace.output_seq != trace.expected)
            record(TRACE_ERROR, now, now, 0, 0, 0, 0, INCOMPLETE);
        record(EXITED, now, now, 0, 0, 0, 0, 0);
        flush_trace();
    }
}

DYLD_INTERPOSE(traced_forkpty, forkpty)
DYLD_INTERPOSE(traced_write, write)
DYLD_INTERPOSE(traced_read, read)
DYLD_INTERPOSE(traced_close, close)

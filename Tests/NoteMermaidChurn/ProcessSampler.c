#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static mach_timebase_info_data_t timebase;

static uint64_t now_ns(void) {
    return (uint64_t)(((__uint128_t)mach_absolute_time() * timebase.numer) / timebase.denom);
}

static void stop(int sig) { (void)sig; stopped = 1; }

static void string(const char *value) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        if (*p == '"' || *p == '\\') printf("\\%c", *p);
        else if (*p < 32 || *p >= 127) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

int main(void) {
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return 2;
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    const uint64_t period = 50000000;
    const uint64_t start = now_ns();
    uint64_t due = start, samples = 0, max_scan = 0, max_late = 0;
    int capacity = proc_listallpids(NULL, 0) * 2 + 1024;
    if (capacity <= 0) return 3;
    pid_t *pids = calloc((size_t)capacity, sizeof(*pids));
    if (!pids) return 4;
    printf("{\"event\":\"sampler-start\",\"pid\":%d,\"startNs\":%" PRIu64 ",\"epochNs\":%" PRIu64 ",\"periodNs\":%" PRIu64 ",\"clock\":\"mach_absolute_time\",\"cpus\":%ld}\n",
           getpid(), start, (uint64_t)time(NULL) * UINT64_C(1000000000), period, sysconf(_SC_NPROCESSORS_ONLN));
    fflush(stdout);
    while (!stopped && now_ns() - start < UINT64_C(650000000000)) {
        uint64_t at = now_ns();
        uint64_t late = at > due ? at - due : 0;
        if (late > max_late) max_late = late;
        int count = proc_listallpids(pids, capacity * (int)sizeof(*pids));
        if (count < 0 || count >= capacity) { free(pids); return 5; }
        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
        if (poll(&input, 1, 0) < 0) { free(pids); return 8; }
        if (input.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
        double load[3] = {0};
        int load_count = getloadavg(load, 3);
        host_cpu_load_info_data_t cpu = {0};
        mach_msg_type_number_t cpu_count = HOST_CPU_LOAD_INFO_COUNT;
        mach_port_t host = mach_host_self();
        kern_return_t cpu_error = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count);
        mach_port_deallocate(mach_task_self(), host);
        printf("{\"event\":\"process-sample\",\"sequence\":%" PRIu64 ",\"startNs\":%" PRIu64 ",\"dueNs\":%" PRIu64 ",\"loadCount\":%d,\"load\":[%.3f,%.3f,%.3f],\"hostCPUError\":%d,\"hostTicks\":[%u,%u,%u,%u],\"processes\":[",
               samples, at, due, load_count, load[0], load[1], load[2], cpu_error,
               cpu.cpu_ticks[CPU_STATE_USER], cpu.cpu_ticks[CPU_STATE_SYSTEM], cpu.cpu_ticks[CPU_STATE_IDLE], cpu.cpu_ticks[CPU_STATE_NICE]);
        int emitted = 0, errors = 0;
        for (int i = 0; i < count; i++) {
            if (pids[i] <= 0) continue;
            struct proc_taskallinfo info = {0};
            uint64_t before = now_ns();
            int bytes = proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info));
            uint64_t after = now_ns();
            if (emitted++) putchar(',');
            printf("{\"pid\":%d,\"startNs\":%" PRIu64 ",\"endNs\":%" PRIu64 ",\"bytes\":%d", pids[i], before, after, bytes);
            if (bytes != (int)sizeof(info)) {
                printf(",\"error\":%d}", errno);
                errors++;
                continue;
            }
            info.pbsd.pbi_name[sizeof(info.pbsd.pbi_name) - 1] = 0;
            info.pbsd.pbi_comm[sizeof(info.pbsd.pbi_comm) - 1] = 0;
            printf(",\"ppid\":%u,\"status\":%u,\"birthUs\":%" PRIu64 ",\"userNs\":%" PRIu64 ",\"systemNs\":%" PRIu64 ",\"threads\":%d,\"runningThreads\":%d,\"name\":",
                   info.pbsd.pbi_ppid, info.pbsd.pbi_status,
                   (uint64_t)info.pbsd.pbi_start_tvsec * UINT64_C(1000000) + info.pbsd.pbi_start_tvusec,
                   info.ptinfo.pti_total_user, info.ptinfo.pti_total_system,
                   info.ptinfo.pti_threadnum, info.ptinfo.pti_numrunning);
            string(info.pbsd.pbi_name[0] ? info.pbsd.pbi_name : info.pbsd.pbi_comm);
            putchar('}');
        }
        uint64_t end = now_ns();
        uint64_t scan = end - at;
        if (scan > max_scan) max_scan = scan;
        printf("],\"endNs\":%" PRIu64 ",\"errors\":%d,\"listed\":%d}\n", end, errors, count);
        fflush(stdout);
        samples++;
        due += period;
        uint64_t now = now_ns();
        if (due < now) due = now + period;
        struct timespec wait = {.tv_sec = 0, .tv_nsec = (long)(due - now)};
        if (!stopped) nanosleep(&wait, NULL);
    }
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) { free(pids); return 6; }
    uint64_t cpu_ns = ((uint64_t)usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * UINT64_C(1000000000)
                    + ((uint64_t)usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000;
    printf("{\"event\":\"sampler-summary\",\"pid\":%d,\"samples\":%" PRIu64 ",\"startNs\":%" PRIu64 ",\"endNs\":%" PRIu64 ",\"cpuNs\":%" PRIu64 ",\"maxScanNs\":%" PRIu64 ",\"maxLatenessNs\":%" PRIu64 "}\n",
           getpid(), samples, start, now_ns(), cpu_ns, max_scan, max_late);
    free(pids);
    return ferror(stdout) ? 7 : 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

__attribute__((constructor)) static void isolate_hook(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
}

static int save_rename(const char *from, const char *to) {
    const char *crash = getenv("EASL_TEST_CRASH_RENAME");
    if (crash && strcmp(to, crash) == 0) {
        fprintf(stderr, "BoardSaveHook crash before rename %s -> %s\n", from, to);
        fflush(stderr);
        _exit(73);
    }
    const char *delay = getenv("EASL_TEST_SAVE_DELAY_MS");
    const char *boards = getenv("EASL_TEST_SAVE_DIRECTORY");
    if (delay && boards && strncmp(to, boards, strlen(boards)) == 0 && to[strlen(boards)] == '/') {
        fprintf(stderr, "BoardSaveHook begin %llu %s\n", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), to);
        fflush(stderr);
        usleep((useconds_t)(strtoul(delay, NULL, 10) * 1000));
        fprintf(stderr, "BoardSaveHook end %llu %s\n", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), to);
        fflush(stderr);
    }
    return rename(from, to);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *original;
} interpose_rename __attribute__((section("__DATA,__interpose"))) = {
    (const void *)save_rename, (const void *)rename
};

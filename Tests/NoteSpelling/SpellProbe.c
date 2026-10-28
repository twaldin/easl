#include <objc/runtime.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <pthread.h>

static IMP original_shared;
static Method shared_method;
static _Atomic uint64_t shared_calls;
static _Atomic int current_phase;
static bool capture_stacks;

static void json_string(const char *text) {
    fputc('"', stderr);
    for (const unsigned char *p = (const unsigned char *)(text ? text : ""); *p; p++) {
        if (*p == '"' || *p == '\\') fputc('\\', stderr);
        if (*p < 32) fprintf(stderr, "\\u%04x", *p);
        else fputc(*p, stderr);
    }
    fputc('"', stderr);
}

static id observed_shared(id self, SEL selector) {
    uint64_t request = atomic_fetch_add_explicit(&shared_calls, 1, memory_order_relaxed) + 1;
    if (capture_stacks) {
        void *frames[64];
        int count = backtrace(frames, 64);
        flockfile(stderr);
        fprintf(stderr, "{\"event\":\"singleton-request\",\"request\":%llu,\"phaseID\":%d,\"mainThread\":%s,\"stack\":[",
                (unsigned long long)request, atomic_load_explicit(&current_phase, memory_order_relaxed),
                pthread_main_np() ? "true" : "false");
        for (int i = 0; i < count; i++) {
            Dl_info info = {0};
            dladdr(frames[i], &info);
            fprintf(stderr, "%s{\"address\":\"%p\",\"image\":", i ? "," : "", frames[i]);
            json_string(info.dli_fname);
            fputs(",\"symbol\":", stderr);
            json_string(info.dli_sname);
            fprintf(stderr, ",\"symbolOffset\":%llu}", info.dli_saddr ?
                    (unsigned long long)((uintptr_t)frames[i] - (uintptr_t)info.dli_saddr) : 0);
        }
        fputs("]}\n", stderr);
        fflush(stderr);
        funlockfile(stderr);
    }
    return ((id (*)(id, SEL))original_shared)(self, selector);
}

void easl_spell_start(bool stacks) {
    shared_method = class_getClassMethod(objc_getClass("NSSpellChecker"), sel_registerName("sharedSpellChecker"));
    if (!shared_method || original_shared) abort();
    capture_stacks = stacks;
    atomic_store_explicit(&shared_calls, 0, memory_order_relaxed);
    atomic_store_explicit(&current_phase, 0, memory_order_relaxed);
    original_shared = method_setImplementation(shared_method, (IMP)observed_shared);
}

void easl_spell_phase(int phase) {
    atomic_store_explicit(&current_phase, phase, memory_order_relaxed);
}

uint64_t easl_spell_calls(void) {
    return atomic_load_explicit(&shared_calls, memory_order_relaxed);
}

void easl_spell_stop(void) {
    method_setImplementation(shared_method, original_shared);
}

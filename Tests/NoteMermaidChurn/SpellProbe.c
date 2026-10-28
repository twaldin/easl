#include <objc/runtime.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

static IMP original_shared;
static Method shared_method;
static _Atomic uint64_t shared_calls;

static id observed_shared(id self, SEL selector) {
    atomic_fetch_add_explicit(&shared_calls, 1, memory_order_relaxed);
    return ((id (*)(id, SEL))original_shared)(self, selector);
}

void easl_spell_start(void) {
    Class checker = objc_getClass("NSSpellChecker");
    shared_method = class_getClassMethod(checker, sel_registerName("sharedSpellChecker"));
    if (!shared_method) abort();
    atomic_store_explicit(&shared_calls, 0, memory_order_relaxed);
    original_shared = method_setImplementation(shared_method, (IMP)observed_shared);
}

uint64_t easl_spell_calls(void) {
    return atomic_load_explicit(&shared_calls, memory_order_relaxed);
}

void easl_spell_stop(void) {
    method_setImplementation(shared_method, original_shared);
}

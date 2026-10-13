/*
 * cpp_exception_stubs.c -- C++ exception runtime stubs for lind-wasm.
 *
 * lind-wasm's libc++abi.a does not yet include the Itanium ABI exception
 * runtime.  These stubs satisfy the linker for benchmarks compiled with
 * -fexceptions; if any are actually called at runtime, the process aborts.
 *
 * Used by SPEC C++ benchmarks (omnetpp and likely parest, xalancbmk,
 * blender) whose codebases use throw/try/catch pervasively as part of
 * their internal error model but do not actually throw on the test
 * workload.
 *
 * Symbols cover the C++ ABI exception API (__cxa_*) plus the Itanium
 * personality function and the unwind API entry points typically
 * referenced by .gcc_except_table metadata.  Nothing here implements
 * real unwinding -- if the program actually throws, abort() fires.
 */

#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>

#define NORETURN __attribute__((noreturn))

/* ---- C++ ABI exception API -------------------------------------------- */

void *__cxa_allocate_exception(size_t thrown_size) {
    (void)thrown_size;
    abort();
}

void __cxa_free_exception(void *thrown_object) {
    (void)thrown_object;
    abort();
}

NORETURN void __cxa_throw(void *thrown_object, void *tinfo,
                          void (*dest)(void *)) {
    (void)thrown_object; (void)tinfo; (void)dest;
    abort();
}

NORETURN void __cxa_rethrow(void) {
    abort();
}

void *__cxa_begin_catch(void *exc) {
    (void)exc;
    abort();
}

void __cxa_end_catch(void) {
    abort();
}

void *__cxa_get_exception_ptr(void *exc) {
    (void)exc;
    abort();
}

NORETURN void __cxa_call_unexpected(void *exc) {
    (void)exc;
    abort();
}

NORETURN void __cxa_pure_virtual(void) {
    abort();
}

NORETURN void __cxa_deleted_virtual(void) {
    abort();
}

/* ---- Personality function and unwind API ------------------------------
 * Referenced via .gcc_except_table / unwind metadata.  Not actually
 * invoked unless an exception fires.
 */

int __gxx_personality_v0(int version, int actions, uint64_t exc_class,
                         void *exc_obj, void *ctx) {
    (void)version; (void)actions; (void)exc_class;
    (void)exc_obj; (void)ctx;
    abort();
}

NORETURN void _Unwind_Resume(void *exc) {
    (void)exc;
    abort();
}

NORETURN void _Unwind_RaiseException(void *exc) {
    (void)exc;
    abort();
}

void _Unwind_DeleteException(void *exc) {
    (void)exc;
}

uintptr_t _Unwind_GetLanguageSpecificData(void *ctx) {
    (void)ctx;
    return 0;
}

uintptr_t _Unwind_GetIP(void *ctx) {
    (void)ctx;
    return 0;
}

void _Unwind_SetIP(void *ctx, uintptr_t ip) {
    (void)ctx; (void)ip;
}

void _Unwind_SetGR(void *ctx, int reg, uintptr_t value) {
    (void)ctx; (void)reg; (void)value;
}

uintptr_t _Unwind_GetRegionStart(void *ctx) {
    (void)ctx;
    return 0;
}

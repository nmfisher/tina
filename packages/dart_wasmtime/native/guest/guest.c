// A pure WASM guest with no imports and no WASI — the Phase 0 test module.
// Exports:
//   add(i32,i32)->i32          trivial-call cost probe
//   count_loop(i32)->i32       bounded loop (instantiation/call probes)
//   spin_cycles(i32,i32)->i32  LONG-RUNNING guest for cancellation tests:
//                              a loop whose trip count LLVM cannot prove at
//                              compile time (indirect through a noinline
//                              helper over a global). 2^31 total iterations
//                              cannot complete inside a test window.
//   divide_by_zero(i32)->i32   trap path (Phase 1 malformed-input fixtures)
// Built by tool/build_guest.dart (clang --target=wasm32 + wasm-ld).
#include <stdint.h>

__attribute__((export_name("add")))
int32_t add(int32_t a, int32_t b) { return a + b; }

static int32_t g_state;

__attribute__((noinline))
static int32_t mix(int32_t x, int32_t n) {
  // LLVM must keep the call: g_state changes on every outer iteration and
  // mix reads it, so it cannot hoist or prove the loop's exit count.
  g_state = g_state ^ (x * 2654435761u) + n;
  return g_state;
}

__attribute__((export_name("spin_cycles")))
int32_t spin_cycles(int32_t n) {
  int32_t acc = 0;
  for (int32_t i = 0; i < n; i++) {
    acc += mix(acc, i);
  }
  return acc;
}

__attribute__((export_name("count_loop")))
int32_t count_loop(int32_t n) {
  int32_t acc = 0;
  for (int32_t i = 0; i < n; i++) {
    acc += i & 1;
  }
  return acc;
}

__attribute__((export_name("divide_by_zero")))
int32_t divide_by_zero(int32_t a) { return 10 / a; }

// Dart bindings for the subset of the Wasmtime C API (v36.0.15) that tina's
// plugin runtime needs. Bound through @Native so the build hook (hook/build.dart)
// resolves symbols against the vendored library. No WASI is bound: tin-w4sm
// forbids host capabilities for API 1.
//
// ABI notes (verified against the v36 headers AND with a C probe program —
// these differ from older wasmtime releases):
//  - engine/store/linker/module/error/trap handles are opaque POINTERS.
//  - `wasmtime_context_t` is a DIFFERENT pointer than the store: get it with
//    wasmtime_store_context(store). Every call/export API takes the context.
//  - wasmtime_instance_t / wasmtime_func_t are BY-VALUE structs:
//    { uint64 store_id; void* __private; } = 16 bytes.
//  - wasmtime_extern_t = { uint8 kind; <pad>; union {func,...} of; } = 24 bytes
//    (union starts at +8, func is 16 bytes).
//  - wasmtime_val_t = { uint8 kind; <pad>; union of; } = 16 bytes.
//  - wasmtime_func_call RETURNS wasmtime_error_t* and takes a
//    wasm_trap_t** out-param as its 7th argument (older releases returned the
//    trap directly).
//  - wasmtime_linker_instantiate takes (linker, context, module, out, trap**).
//  - With epoch interruption enabled, every store starts at deadline 0: calls
//    trap "wasm trap: interrupt" until set_epoch_deadline arms them.

@ffi.DefaultAsset('package:dart_wasmtime/dart_wasmtime.dart')
library;

import 'dart:ffi' as ffi;

const int kValKindI32 = 0;
const int kValKindI64 = 1;
const int kValKindF32 = 2;
const int kValKindF64 = 3;
const int kExternKindFunc = 0;

/// sizeof(wasmtime_val_t) and sizeof(wasmtime_instance_t) /
/// sizeof(wasmtime_func_t): {u64 store_id; void* private} and {u8 kind; pad;
/// union} respectively, on every ABI we ship.
const int kValSize = 24;
const int kInstanceSize = 16;
const int kExternSize = 32;

/// Finalizer signature: void (*)(void*). See WasmtimeFinalizerNative below.

// --- engine / config ---------------------------------------------------------

@ffi.Native<ffi.Pointer<ffi.Void> Function()>()
external ffi.Pointer<ffi.Void> wasm_config_new();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasm_config_delete(ffi.Pointer<ffi.Void> config);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint8)>()
external void wasmtime_config_consume_fuel_set(
    ffi.Pointer<ffi.Void> config, int enable);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint8)>()
external void wasmtime_config_epoch_interruption_set(
    ffi.Pointer<ffi.Void> config, int enable);

@ffi.Native<ffi.Pointer<ffi.Void> Function()>()
external ffi.Pointer<ffi.Void> wasm_engine_new();

/// Takes ownership of `config`.
@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Void> wasm_engine_new_with_config(
    ffi.Pointer<ffi.Void> config);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasm_engine_delete(ffi.Pointer<ffi.Void> engine);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasmtime_engine_increment_epoch(ffi.Pointer<ffi.Void> engine);

// --- module ------------------------------------------------------------------

/// Returns a wasmtime_error_t* (null on success). Caller owns the error.
@ffi.Native<
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>, ffi.Size, ffi.Pointer<ffi.Pointer<ffi.Void>>)>()
external ffi.Pointer<ffi.Void> wasmtime_module_new(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Uint8> wasm,
    int wasmLen,
    ffi.Pointer<ffi.Pointer<ffi.Void>> moduleOut);

/// Returns a wasmtime_error_t* (null when the bytes validate).
@ffi.Native<
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Size)>()
external ffi.Pointer<ffi.Void> wasmtime_module_validate(
    ffi.Pointer<ffi.Void> engine, ffi.Pointer<ffi.Uint8> wasm, int wasmLen);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasmtime_module_delete(ffi.Pointer<ffi.Void> module);

// --- store / linker / instance -----------------------------------------------

/// C: store_new(engine, void* data, void (*finalizer)(void*)).
@ffi.Native<
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
        ffi.Pointer<WasmtimeFinalizerNative>)>()
external ffi.Pointer<ffi.Void> wasmtime_store_new(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Void> storeData,
    ffi.Pointer<WasmtimeFinalizerNative> finalizer);

/// The context is what every call/export API actually takes.
@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Void> wasmtime_store_context(
    ffi.Pointer<ffi.Void> store);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasmtime_store_delete(ffi.Pointer<ffi.Void> store);

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Void> wasmtime_linker_new(
    ffi.Pointer<ffi.Void> engine);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasmtime_linker_delete(ffi.Pointer<ffi.Void> linker);

/// C: instantiate(linker, context, module, wasmtime_instance_t* out,
/// wasm_trap_t** trap). Returns error* (null on success — check trap too).
@ffi.Native<
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>, // wasmtime_instance_t* (16-byte by-value struct)
        ffi.Pointer<ffi.Pointer<ffi.Void>>)>()
external ffi.Pointer<ffi.Void> wasmtime_linker_instantiate(
    ffi.Pointer<ffi.Void> linker,
    ffi.Pointer<ffi.Void> context,
    ffi.Pointer<ffi.Void> module,
    ffi.Pointer<ffi.Uint8> instanceOut,
    ffi.Pointer<ffi.Pointer<ffi.Void>> trapOut);

/// C: instance_export_get(context, const wasmtime_instance_t*, name, len,
/// wasmtime_extern_t* item) -> bool.
@ffi.Native<
    ffi.Uint8 Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>, // const wasmtime_instance_t*
        ffi.Pointer<ffi.Uint8>,
        ffi.Size,
        ffi.Pointer<ffi.Uint8>)>()
external int wasmtime_instance_export_get(
    ffi.Pointer<ffi.Void> context,
    ffi.Pointer<ffi.Uint8> instance,
    ffi.Pointer<ffi.Uint8> name,
    int nameLen,
    ffi.Pointer<ffi.Uint8> itemOut);

// --- func / values -----------------------------------------------------------

/// wasm_valtype_t* for one kind (WASM_I32 = 0, WASM_I64 = 1, ...).
@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Uint8)>()
external ffi.Pointer<ffi.Void> wasm_valtype_new(int kind);

/// Takes ownership of both wasm_valtype_vec_t* (see _valtypeVec in
/// wasmtime_runtime.dart, which builds the {size, data} pair on the heap).
@ffi.Native<
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Void> wasm_functype_new(
    ffi.Pointer<ffi.Void> paramsVec, ffi.Pointer<ffi.Void> resultsVec);

/// C: func_call(context, const wasmtime_func_t*, args, nargs, results,
/// nresults, wasm_trap_t** trap) -> wasmtime_error_t*.
@ffi.Native<
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>, // const wasmtime_func_t* (16-byte struct)
        ffi.Pointer<ffi.Uint8>,
        ffi.Size,
        ffi.Pointer<ffi.Uint8>,
        ffi.Size,
        ffi.Pointer<ffi.Pointer<ffi.Void>>)>()
external ffi.Pointer<ffi.Void> wasmtime_func_call(
    ffi.Pointer<ffi.Void> context,
    ffi.Pointer<ffi.Uint8> func,
    ffi.Pointer<ffi.Uint8> args,
    int numArgs,
    ffi.Pointer<ffi.Uint8> results,
    int numResults,
    ffi.Pointer<ffi.Pointer<ffi.Void>> trapOut);

/// C: void wasmtime_func_new(context, functype, cb, env, finalizer, out).
typedef WasmtimeHostCallbackNative = ffi.NativeFunction<
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void> env,
        ffi.Pointer<ffi.Void> caller,
        ffi.Pointer<ffi.Uint8> args,
        ffi.Size nargs,
        ffi.Pointer<ffi.Uint8> results,
        ffi.Size nresults)>;

typedef WasmtimeFinalizerNative = ffi.NativeFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void> env)>;

@ffi.Native<
    ffi.Void Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<WasmtimeHostCallbackNative>,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<WasmtimeFinalizerNative>,
        ffi.Pointer<ffi.Uint8>)>() // wasmtime_func_t* out
external void wasmtime_func_new(
    ffi.Pointer<ffi.Void> context,
    ffi.Pointer<ffi.Void> functype,
    ffi.Pointer<WasmtimeHostCallbackNative> callback,
    ffi.Pointer<ffi.Void> env,
    ffi.Pointer<WasmtimeFinalizerNative> finalizer,
    ffi.Pointer<ffi.Uint8> funcOut);

// --- fuel / epochs -----------------------------------------------------------

/// Returns 1 when fuel is available (must be enabled on the config), else 0.
@ffi.Native<ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int64>)>()
external int wasmtime_context_get_fuel(
    ffi.Pointer<ffi.Void> context, ffi.Pointer<ffi.Int64> fuelOut);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint64)>()
external void wasmtime_context_set_fuel(
    ffi.Pointer<ffi.Void> context, int fuel);

/// Arms the store's deadline [ticks] epochs beyond the current one. With epoch
/// interruption on, an unarmed store traps immediately.
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint64)>()
external void wasmtime_context_set_epoch_deadline(
    ffi.Pointer<ffi.Void> context, int ticksBeyondCurrent);

// --- traps / errors ----------------------------------------------------------

/// Returns a wasmtime_trap_code_t value, or 0 when the trap has no code.
@ffi.Native<ffi.Uint8 Function(ffi.Pointer<ffi.Void>)>()
external int wasmtime_trap_code(ffi.Pointer<ffi.Void> trap);

/// C: void wasm_trap_delete(wasm_trap_t*) — wasm-c-api spelling.
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasm_trap_delete(ffi.Pointer<ffi.Void> trap);

/// C: void wasm_trap_message(const wasm_trap_t*, wasm_name_t* message) —
/// the wasm-c-api spelling (there is no wasmtime_trap_message in v36).
@ffi.Native<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.UintPtr>)>()
external void wasm_trap_message(
    ffi.Pointer<ffi.Void> trap, ffi.Pointer<ffi.UintPtr> messageOut);

/// Fills `messageOut` (a wasm_name_t = {size, data}); free with
/// wasm_byte_vec_delete.
@ffi.Native<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.UintPtr>)>()
external void wasmtime_error_message(
    ffi.Pointer<ffi.Void> error, ffi.Pointer<ffi.UintPtr> messageOut);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasmtime_error_delete(ffi.Pointer<ffi.Void> error);

/// C: void wasm_byte_vec_delete(wasm_byte_vec_t*).
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void wasm_byte_vec_delete(ffi.Pointer<ffi.Void> vec);

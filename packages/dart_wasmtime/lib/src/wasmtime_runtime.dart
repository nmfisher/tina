// Thin idiomatic layer over wasmtime_bindings.dart. Phase 0 uses compile /
// validate / instantiate / call plus epoch interruption; no WASI, no host
// imports. Native handles are explicit: everything this file's classes create
// is freed in [close]; nothing relies on GC finalizers.
//
// ABI shape (see wasmtime_bindings.dart for the full notes): instances and
// funcs are 16-byte by-value structs, calls take the store's *context* pointer,
// and epoch-interrupted stores need set_epoch_deadline re-armed before each
// call.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'wasmtime_bindings.dart';

export 'wasmtime_bindings.dart'
    show
        kExternKindFunc,
        kExternSize,
        kInstanceSize,
        kValKindF32,
        kValKindF64,
        kValKindI32,
        kValKindI64,
        kValSize;

/// A list of native allocations to free together. Used for per-call scratch
/// (guest bytes, name buffers, val arrays) so a call site cannot leak or
/// double-free one buffer.
final class WasmtimeScope {
  final List<ffi.Pointer<ffi.Void>> _allocations = [];

  ffi.Pointer<ffi.Uint8> allocBytes(Uint8List bytes) {
    final p = malloc<ffi.Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    _allocations.add(p.cast());
    return p;
  }

  ffi.Pointer<ffi.Uint8> allocString(String s) =>
      allocBytes(Uint8List.fromList(utf8.encode(s)));

  ffi.Pointer<T> allocRaw<T extends ffi.NativeType>(int bytes) {
    // malloc's type parameter must be a constant; allocate bytes and retype.
    // Zero the memory: wasmtime writes its out-params (instance, trap) only on
    // failure paths, so a caller-read of untouched malloc memory would look
    // like a valid handle and crash later. This is the memset() the C samples
    // do.
    final p = malloc<ffi.Uint8>(bytes);
    p.asTypedList(bytes).fillRange(0, bytes, 0);
    _allocations.add(p.cast());
    return ffi.Pointer.fromAddress(p.address);
  }

  void dispose() {
    for (final p in _allocations) {
      malloc.free(p);
    }
    _allocations.clear();
  }
}

ffi.Pointer<ffi.Uint8> _at(ffi.Pointer<ffi.Uint8> p, int offset) =>
    ffi.Pointer.fromAddress(p.address + offset);

/// Reads a wasm_name_t {size, data} into a Dart string and frees it.
String _nameToString(ffi.Pointer<ffi.UintPtr> name) {
  final n = name[0];
  final data = ffi.Pointer<ffi.Uint8>.fromAddress(name[1]);
  final s = utf8.decode(data.asTypedList(n), allowMalformed: true);
  wasm_byte_vec_delete(name.cast());
  return s;
}

/// Reads a wasmtime_error_t* into a Dart string and deletes the error.
String errorMessage(ffi.Pointer<ffi.Void> error) {
  final scope = WasmtimeScope();
  try {
    final name = scope.allocRaw<ffi.UintPtr>(2);
    wasmtime_error_message(error, name);
    return _nameToString(name);
  } finally {
    scope.dispose();
  }
}

/// Reads a wasm_trap_t* into a Dart string and deletes the trap.
String trapMessage(ffi.Pointer<ffi.Void> trap) {
  final scope = WasmtimeScope();
  try {
    final name = scope.allocRaw<ffi.UintPtr>(2);
    wasm_trap_message(trap, name);
    return _nameToString(name);
  } finally {
    scope.dispose();
  }
}

/// Engine + config. One engine per worker process; long-running guests are cut
/// off through epoch interruption, which needs no cooperation from guest code.
/// NOTE: with epoch interruption on, every store starts UNARMED (deadline 0)
/// and traps until setEpochDeadline arms it — see [WasmtimeInstance].
final class WasmtimeEngine {
  WasmtimeEngine({bool epochInterruption = true, bool autoArm = false})
      : _epochInterruption = epochInterruption,
        _autoArm = autoArm {
    final config = wasm_config_new();
    if (epochInterruption) {
      wasmtime_config_epoch_interruption_set(config, 1);
    }
    _engine = wasm_engine_new_with_config(config); // owns config
  }

  /// When interruption is on but [autoArm] is false, stores trap unless armed
  /// manually (strict supervision). [autoArm] re-arms every call with
  /// [autoArmTicks], which is what non-worker callers want.
  final bool _epochInterruption;
  final bool _autoArm;

  /// Whether calls on stores of this engine should self-arm each call.
  bool get shouldSelfArm => _epochInterruption && _autoArm;

  late final ffi.Pointer<ffi.Void> _engine;
  bool _closed = false;

  ffi.Pointer<ffi.Void> get handle {
    _ensureOpen();
    return _engine;
  }

  /// Advances the engine's epoch by one: every armed store whose deadline is
  /// now past traps at its next epoch check.
  void bumpEpoch() {
    _ensureOpen();
    wasmtime_engine_increment_epoch(_engine);
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    wasm_engine_delete(_engine);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('WasmtimeEngine already closed');
    }
  }
}

class WasmtimeException implements Exception {
  WasmtimeException(this.message);
  final String message;
  @override
  String toString() => 'WasmtimeException: $message';
}

/// A compiled module. Constructing one validates the bytes first; [validate]
/// stays public for pre-activation checks (Phase 1).
final class WasmtimeModule {
  WasmtimeModule(this.engine, Uint8List wasm) {
    final scope = WasmtimeScope();
    try {
      final bytes = scope.allocBytes(wasm);
      final err = wasmtime_module_validate(engine.handle, bytes, wasm.length);
      if (err != ffi.nullptr) {
        final msg = errorMessage(err);
        wasmtime_error_delete(err);
        throw WasmtimeException('module invalid: $msg');
      }
      final out =
          scope.allocRaw<ffi.Pointer<ffi.Void>>(ffi.sizeOf<ffi.Pointer<ffi.Void>>());
      final err2 = wasmtime_module_new(engine.handle, bytes, wasm.length, out);
      if (err2 != ffi.nullptr) {
        final msg = errorMessage(err2);
        wasmtime_error_delete(err2);
        throw WasmtimeException('compile failed: $msg');
      }
      _module = out.value;
    } finally {
      scope.dispose();
    }
  }

  final WasmtimeEngine engine;
  late final ffi.Pointer<ffi.Void> _module;
  bool _closed = false;

  ffi.Pointer<ffi.Void> get handle {
    _ensureOpen();
    return _module;
  }

  static bool validate(WasmtimeEngine engine, Uint8List wasm) {
    final scope = WasmtimeScope();
    try {
      final bytes = scope.allocBytes(wasm);
      final err = wasmtime_module_validate(engine.handle, bytes, wasm.length);
      if (err == ffi.nullptr) {
        return true;
      }
      wasmtime_error_delete(err);
      return false;
    } finally {
      scope.dispose();
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    wasmtime_module_delete(_module);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('WasmtimeModule already closed');
    }
  }
}

/// One live instantiation. All native state behind this handle dies with it:
/// [close] frees the linker and the store; the instance and its funcs live in
/// the store.
final class WasmtimeInstance {
  WasmtimeInstance._({
    required ffi.Pointer<ffi.Void> store,
    required ffi.Pointer<ffi.Void> linker,
    required ffi.Pointer<ffi.Uint8> instance,
  })  : _store = store,
        _linker = linker,
        _instance = instance {
    // Contexts are borrowed from the store, so cache the pointer only.
    _context = wasmtime_store_context(store);
  }

  final ffi.Pointer<ffi.Void> _store;
  final ffi.Pointer<ffi.Void> _linker;
  final ffi.Pointer<ffi.Uint8> _instance; // wasmtime_instance_t (16 B)
  late final ffi.Pointer<ffi.Void> _context;
  bool _closed = false;

  WasmtimeEngine? _engine;

  /// Constructor keep-alive: the instance cannot outlive its engine.
  // ignore: unused_element
  WasmtimeEngine? get engine => _engine;

  /// Arms the store's epoch deadline [ticks] beyond the current epoch. With
  /// epoch interruption enabled a store starts UNARMED (deadline 0): a call
  /// traps "wasm trap: interrupt" almost immediately unless armed first. Arm
  /// before every call; this is what makes cancellation possible without
  /// guest cooperation. Convenience: [callI32] arms automatically when
  /// [WasmtimeEngine.autoArm] was on at construction.
  void setEpochDeadline(int ticks) {
    _ensureOpen();
    wasmtime_context_set_epoch_deadline(_context, ticks);
  }

  /// Calls an exported `name(i32...) -> i32` function — the Phase 0 guest
  /// shape. The general ABI (strings, structs) lands in Phase 1.
  int callI32(String name, List<int> args) {
    _ensureOpen();
    final eng = _engine;
    if (eng != null && eng.shouldSelfArm) {
      wasmtime_context_set_epoch_deadline(_context, 1000000000);
    }
    return callI32Raw(_context, _instance, name, args);
  }

  /// [callI32] from raw handles: what the supervised worker uses so the
  /// blocking `wasmtime_func_call` can run on a helper isolate while the
  /// worker's main isolate stays free to answer cancel/shutdown by bumping
  /// the engine epoch (epoch interruption is cross-thread by design).
  /// The caller owns serialization: a store must never be entered from two
  /// threads at once.
  static int callI32Raw(
    ffi.Pointer<ffi.Void> context,
    ffi.Pointer<ffi.Uint8> instance,
    String name,
    List<int> args,
  ) {
    final scope = WasmtimeScope();
    try {
      final func = _exportFuncRaw(context, instance, name, scope);
      final argsPtr = scope.allocRaw<ffi.Uint8>(args.length * kValSize);
      for (var i = 0; i < args.length; i++) {
        _writeI32(argsPtr, i, args[i]);
      }
      final resultsPtr = scope.allocRaw<ffi.Uint8>(kValSize);
      final trapPtr = scope
          .allocRaw<ffi.Pointer<ffi.Void>>(ffi.sizeOf<ffi.Pointer<ffi.Void>>());
      final err = wasmtime_func_call(context, func, argsPtr, args.length,
          resultsPtr, 1, trapPtr);
      final trap = trapPtr.value;
      if (err != ffi.nullptr) {
        final msg = errorMessage(err);
        wasmtime_error_delete(err);
        if (trap != ffi.nullptr) {
          wasm_trap_delete(trap);
        }
        throw WasmtimeException('call "$name" failed: $msg');
      }
      if (trap != ffi.nullptr) {
        final msg = trapMessage(trap);
        wasm_trap_delete(trap);
        throw WasmtimeException('call "$name" trapped: $msg');
      }
      return _readI32(resultsPtr, 0);
    } finally {
      scope.dispose();
    }
  }

  /// Addresses of the context and instance handles, for [callI32Raw] callers
  /// (worker helper isolates). Valid until [close].
  int get contextAddress => _context.address;
  int get instanceAddress => _instance.address;

  /// wasmtime_func_t* (16-byte by-value struct) for export [name]. The
  /// returned pointer lives in [scope] — it must not outlive it.
  static ffi.Pointer<ffi.Uint8> _exportFuncRaw(
    ffi.Pointer<ffi.Void> context,
    ffi.Pointer<ffi.Uint8> instance,
    String name,
    WasmtimeScope scope,
  ) {
    final n = scope.allocString(name);
    final item = scope.allocRaw<ffi.Uint8>(kExternSize); // wasmtime_extern_t (kind@0, of.func@+8)
    final ok = wasmtime_instance_export_get(
        context, instance, n, name.length, item);
    final kind = item[0];
    // of.func starts at +8: {u64 store_id; void* __private}.
    final funcPtr = _at(item, 8);
    if (ok == 0 || kind != kExternKindFunc) {
      throw WasmtimeException('export "$name" not found or not a func');
    }
    return funcPtr;
  }

  /// wasmtime_val_t: kind byte at +0, i32 payload at +8.
  static void _writeI32(ffi.Pointer<ffi.Uint8> vals, int index, int v) {
    final base = _at(vals, index * kValSize);
    base[0] = kValKindI32; // kind first
    base.cast<ffi.Int32>()[2] = v; // union payload at +8
  }

  /// Public so the probe tests can compare raw layouts.
  static int debugKindAt(ffi.Pointer<ffi.Uint8> vals, int index) =>
      _at(vals, index * kValSize)[8];

  static int _readI32(ffi.Pointer<ffi.Uint8> vals, int index) {
    final base = _at(vals, index * kValSize);
    final kind = base[0];
    if (kind != kValKindI32) {
      throw WasmtimeException('unexpected result kind $kind');
    }
    return base.cast<ffi.Int32>()[2]; // union payload at +8
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    wasmtime_linker_delete(_linker);
    wasmtime_store_delete(_store);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('WasmtimeInstance already closed');
    }
  }

  /// Copies a wasmtime_instance_t out of scratch memory. The struct is passed
  /// by value to the C API, but our handle must stay valid after the
  /// instantiation scope is disposed — using freed scratch here produced
  /// "object used with the wrong store" aborts (Phase 0 debugging note).
  static ffi.Pointer<ffi.Uint8> _copyInstance(ffi.Pointer<ffi.Uint8> src) {
    final dst = malloc<ffi.Uint8>(kInstanceSize);
    dst.asTypedList(kInstanceSize)
        .setAll(0, src.asTypedList(kInstanceSize));
    return dst;
  }

  /// Instantiates [module] in [engine]. The instance may not outlive the
  /// engine.
  static WasmtimeInstance instantiate(
      WasmtimeEngine engine, WasmtimeModule module) {
    final scope = WasmtimeScope();
    ffi.Pointer<ffi.Void>? store;
    ffi.Pointer<ffi.Void>? linker;
    try {
      store = wasmtime_store_new(engine.handle, ffi.nullptr, ffi.nullptr);
      linker = wasmtime_linker_new(engine.handle);
      final instanceOut = scope.allocRaw<ffi.Uint8>(kInstanceSize);
      final trapPtr = scope
          .allocRaw<ffi.Pointer<ffi.Void>>(ffi.sizeOf<ffi.Pointer<ffi.Void>>());
      final err = wasmtime_linker_instantiate(linker,
          wasmtime_store_context(store), module.handle, instanceOut, trapPtr);
      final trap = trapPtr.value;
      if (err != ffi.nullptr) {
        final msg = errorMessage(err);
        wasmtime_error_delete(err);
        if (trap != ffi.nullptr) {
          wasm_trap_delete(trap);
        }
        throw WasmtimeException('instantiate failed: $msg');
      }
      if (trap != ffi.nullptr) {
        final msg = trapMessage(trap);
        wasm_trap_delete(trap);
        throw WasmtimeException('instantiate trapped: $msg');
      }
      final inst = WasmtimeInstance._(
          store: store,
          linker: linker,
          // instanceOut is scope scratch freed below; wasmtime_instance_t is a
          // by-value 16-byte struct, so copy it into memory the instance owns.
          instance: _copyInstance(instanceOut));
      inst._engine = engine;
      return inst;
    } on Object {
      // Never leak a partially built instance.
      if (linker != null) {
        wasmtime_linker_delete(linker);
      }
      if (store != null) {
        wasmtime_store_delete(store);
      }
      rethrow;
    } finally {
      scope.dispose();
    }
  }
}

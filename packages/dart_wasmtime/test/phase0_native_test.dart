// Phase 0 native verification (tin-w4sm). These tests run REAL Wasmtime
// against a REAL compiled guest in a REAL supervised worker process. No mocks,
// no interpreters — the ticket explicitly forbids substituting those for
// packaging, ABI, cancellation, and lifecycle verification.
//
// What each group proves:
//   packaging       the vendored static archive resolves through the build
//                   hook and the @Native bindings bind real symbols
//   ABI             guest bytes compile/instantiate; calls cross the boundary
//   cancellation    a long-running guest is cut off by epoch interruption and
//                   the worker process is joined (reaped), not merely replied to
//   lifecycle       teardown joins owned work; nothing is left running
//
// The guest is pure (no imports, no WASI). See native/guest/guest.c.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_wasmtime/dart_wasmtime.dart';
import 'package:test/test.dart';

Uint8List _guestBytes() =>
    Uint8List.fromList(File('native/guest/guest.wasm').readAsBytesSync());

PluginWorkerSupervisor _spawn() {
  final s = PluginWorkerSupervisor();
  addTearDown(() => s.stop());
  return s;
}

Future<bool> _pidIsGone(int pid) async {
  if (Platform.isWindows) {
    // No signal 0 on Windows; Phase 0 has no Windows target anyway.
    throw UnsupportedError('pid liveness probe unsupported on Windows');
  }
  // `kill -0` probes liveness without signalling: exit 0 = alive.
  final r = await Process.run('kill', ['-0', '$pid']);
  return r.exitCode != 0;
}

String _osArch() {
  final os = Platform.operatingSystem; // linux | macos
  final abi = ffi.Abi.current();
  final arch = switch (abi) {
    ffi.Abi.macosArm64 => 'arm64',
    ffi.Abi.linuxArm64 => 'arm64',
    ffi.Abi.linuxX64 => 'x64',
    _ => throw UnsupportedError('no vendored wasmtime for $abi'),
  };
  return '${os}_$arch';
}

void main() {
  test('packaging: engine comes up and validates real guest bytes', () {
    final engine = WasmtimeEngine();
    try {
      final bytes = _guestBytes();
      expect(bytes.length, greaterThan(0));
      expect(WasmtimeModule.validate(engine, bytes), isTrue,
          reason: 'the checked-in guest must validate against the vendored '
              'engine on this target');
      // Invalid bytes must be rejected by the real validator, not skipped.
      final garbage = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      expect(WasmtimeModule.validate(engine, garbage), isFalse);
    } finally {
      engine.close();
    }
  });

  test('ABI: compile, instantiate, and call a pure guest (engine-side smoke '
      'of the exported symbols)', () {
    final engine = WasmtimeEngine();
    try {
      final module = WasmtimeModule(engine, _guestBytes());
      final instance = WasmtimeInstance.instantiate(engine, module);
      try {
        // epoch interruption is on, so the store starts UNARMED (deadline 0):
        // an unarmed call traps "interrupt" immediately. Engine-side callers
        // arm explicitly — the supervised worker does this per call.
        instance.setEpochDeadline(1000000);
        expect(instance.callI32('add', [2, 3]), 5);
        expect(instance.callI32('add', [-7, 7]), 0);
        expect(instance.callI32('count_loop', [1000000]), 500000);
      } finally {
        instance.close();
        module.close();
      }
    } finally {
      engine.close();
    }
  });

  test('supervised worker: guest runs in a separate PROCESS, never in the '
      'test isolate', () async {
    final s = _spawn();
    await s.start();
    final pong = await s.ping();
    final workerPid = (pong['result'] as Map)['pid'] as int;
    expect(workerPid, isNot(pid),
        reason: 'the worker must be its own process');

    await s.load(_guestBytes());
    // Cross-process round trip through real wasmtime.
    expect(await s.call('add', [20, 22]), 42);
  });

  test('cancellation: a long-running guest is cut off and the worker is '
      'JOINED (process reaped), nothing left running', () async {
    final s = _spawn();
    await s.start();
    final pong = await s.ping();
    final workerPid = (pong['result'] as Map)['pid'] as int;

    await s.load(_guestBytes());

    // spin_cycles(INT32_MAX) will not finish on its own (the guest export
    // takes an i32; a 2^60 trip count would silently truncate to 0).
    final callFuture = s.call('spin_cycles', [0x7fffffff]);
    var callSettled = false;
    unawaited(callFuture
        .then((_) => callSettled = true, onError: (_) => callSettled = true));

    // Give the guest time to actually be spinning.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(callSettled, isFalse, reason: 'guest should still be running');

    final cancelStart = DateTime.now();
    await s.cancel();
    // The in-flight call must fail with the cancellation, not hang.
    await expectLater(callFuture, throwsA(isA<WorkerCallException>()));
    final cancelDuration = DateTime.now().difference(cancelStart);

    // Join: the worker process must actually exit and be reaped.
    await s.stop();
    await s.exited;
    expect(s.exitCodeOf, isNotNull,
        reason: 'worker process must be reaped, not merely replied to');

    // Nothing left running: the pid must be gone.
    expect(await _pidIsGone(workerPid), isTrue,
        reason: 'worker pid $workerPid must not outlive supervision');

    // Epoch interruption is near-immediate; 3s is a generous ceiling.
    expect(cancelDuration, lessThan(const Duration(seconds: 3)),
        reason: 'cancellation took $cancelDuration');
  });

  test('lifecycle: shutdown joins owned work and the process exits cleanly',
      () async {
    final s = _spawn();
    await s.start();
    final pong = await s.ping();
    final workerPid = (pong['result'] as Map)['pid'] as int;
    await s.load(_guestBytes());
    await s.call('add', [1, 2]);

    await s.stop();
    await s.exited;
    expect(s.exitCodeOf, 0, reason: 'clean shutdown exits 0');
    expect(await _pidIsGone(workerPid), isTrue);
  });

  test('lifecycle: a supervisor crash (stdin closed) joins the worker too',
      () async {
    final s = _spawn();
    await s.start();
    final pong = await s.ping();
    final workerPid = (pong['result'] as Map)['pid'] as int;

    // Close stdin without a shutdown request: the worker must notice and join.
    s.process!.stdin.close();
    await s.exited.timeout(const Duration(seconds: 30));
    expect(await _pidIsGone(workerPid), isTrue,
        reason: 'worker must join when the supervisor pipe closes');
  });

  test('measurements: instantiation time, trivial call cost, cancellation '
      'latency (printed for the ticket record)', () async {
    // autoArm: engine-side measurement calls must self-arm an epoch deadline;
    // an unarmed store traps "interrupt" immediately by design.
    final engine = WasmtimeEngine(autoArm: true);
    final sw = Stopwatch();

    sw.start();
    final module = WasmtimeModule(engine, _guestBytes());
    final compileUs = sw.elapsedMicroseconds;
    sw.reset();
    final instance = WasmtimeInstance.instantiate(engine, module);
    final instantiateUs = sw.elapsedMicroseconds;

    // Warm the call path, then measure a trivial call.
    instance.callI32('add', [1, 1]);
    const n = 1000;
    sw.reset();
    var acc = 0;
    for (var i = 0; i < n; i++) {
      acc += instance.callI32('add', [i, 1]);
    }
    final perCallUs = sw.elapsedMicroseconds / n;
    expect(acc, greaterThan(0));
    expect(perCallUs, lessThan(1000),
        reason: 'a trivial call should be microseconds, not milliseconds');

    // In-worker numbers (the sanctioned path).
    final s = PluginWorkerSupervisor();
    addTearDown(s.stop);
    await s.start();
    final t0 = DateTime.now();
    await s.load(_guestBytes());
    final loadMs = DateTime.now().difference(t0).inMilliseconds;
    sw.reset();
    await s.call('add', [1, 2]);
    final workerCallMs = sw.elapsedMilliseconds;

    // Cancellation latency in the worker.
    final spin = s.call('spin_cycles', [0x7fffffff]);
    unawaited(spin.catchError((Object _) => -1));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final c0 = DateTime.now();
    await s.cancel();
    await expectLater(spin, throwsA(isA<WorkerCallException>()));
    final cancelMs = DateTime.now().difference(c0).inMilliseconds;
    await s.stop();

    final lib = File('native/lib/${_osArch()}/libwasmtime.a');
    // ignore: avoid_print
    print('=== PHASE 0 MEASUREMENTS (${_osArch()}) ===');
    // ignore: avoid_print
    print('guest.wasm bytes: ${_guestBytes().length}');
    // ignore: avoid_print
    print('compile (validate+compile): $compileUs us');
    // ignore: avoid_print
    print('instantiate: $instantiateUs us');
    // ignore: avoid_print
    print(
        'trivial call, in-process (n=1000): ${perCallUs.toStringAsFixed(1)} us/call');
    // ignore: avoid_print
    print('worker load+instantiate round trip: $loadMs ms');
    // ignore: avoid_print
    print('worker trivial call round trip: $workerCallMs ms');
    // ignore: avoid_print
    print('worker cancellation latency: $cancelMs ms');
    // ignore: avoid_print
    print('vendored libwasmtime.a: ${lib.lengthSync()} B');

    instance.close();
    module.close();
    engine.close();
  });
}

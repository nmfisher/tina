// Supervised plugin worker (tin-w4sm Phase 0). One process per guest class;
// stdin/stdout line-JSON protocol with the supervisor (lib/src/worker.dart).
//
// Threading model — this is the part that makes cancellation actually work:
//
//   * wasmtime_func_call is synchronous and BLOCKS. If it ran on the main
//     isolate, the event loop could not read stdin, so a `cancel` line could
//     never be handled while a long-running guest spun — the supervisor would
//     deadlock instead of cancelling. The blocking call therefore runs on a
//     HELPER isolate.
//   * The main isolate stays responsive: it answers `cancel` by bumping the
//     engine epoch. Wasmtime's epoch interruption is cross-thread — a guest
//     executing on the helper isolate traps "interrupt" at its next epoch
//     check even though the bump happened on the main thread. That is the
//     designed use of epoch interruption; it is why no guest cooperation and
//     no polling is needed.
//   * The helper isolate never loads, never tears down, and never touches the
//     store outside its single call: a store must never be entered from two
//     threads at once, so guest execution is serialized (one call in flight
//     per worker, enforced here).
//
// Epoch deadlines: stores start UNARMED (deadline 0) when epoch interruption
// is on — an unarmed call traps "interrupt" immediately. The worker arms a
// deadline of [epochGrace] epochs BEFORE each call is dispatched (arming is
// rebased on the current epoch, so it must precede any cancel bump), so a
// guest only ever runs while the supervisor is actively driving it; losing
// the supervisor (pipe close) can't leave a guest spinning unattended.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io';

import 'package:dart_wasmtime/dart_wasmtime.dart';

void main() {
  final engine = WasmtimeEngine(epochInterruption: true);
  const epochGrace = 1;
  WasmtimeModule? module;
  WasmtimeInstance? instance;
  var cancelled = false;
  var callActive = false;
  Isolate? callHelper;

  void reply(Map<String, Object?> msg) => stdout.writeln(jsonEncode(msg));

  void fail(int id, String message) =>
      reply({'id': id, 'ok': false, 'error': message});

  void ok(int id, [Object? result]) =>
      reply({'id': id, 'ok': true, 'result': result});

  // -- guest calls run on a helper isolate ----------------------------------

  /// Runs one blocking `wasmtime_func_call` on a short-lived helper isolate.
  /// The main isolate's event loop stays free, so `cancel` (epoch bump) and
  /// `shutdown` are handled while the guest spins.
  Future<int> runCallOnHelper(
      WasmtimeInstance inst, String name, List<int> args) {
    final done = Completer<int>();
    final replies = ReceivePort();
    final errors = ReceivePort();
    void closePorts() {
      replies.close();
      errors.close();
    }

    replies.listen((msg) {
      if (!done.isCompleted) {
        done.complete(msg as int);
      }
      closePorts();
    });
    errors.listen((msg) {
      if (!done.isCompleted) {
        done.completeError(msg is Exception ? msg : WasmtimeException('$msg'));
      }
      closePorts();
    });
    unawaited(() async {
      try {
        callHelper = await Isolate.spawn(
          _helperEntry,
          _HelperMsg(
            reply: replies.sendPort,
            errors: errors.sendPort,
            context: inst.contextAddress,
            instance: inst.instanceAddress,
            name: name,
            args: args,
          ),
          debugName: 'wasm-call',
        );
      } on Object catch (e) {
        if (!done.isCompleted) {
          done.completeError(WasmtimeException('helper spawn failed: $e'));
        }
        closePorts();
      }
    }());
    return done.future;
  }

  /// Joins a helper that may still be inside a guest call. The caller bumps
  /// the epoch first so the guest traps instead of spinning.
  Future<void> joinCallHelper() async {
    final iso = callHelper;
    if (iso == null) {
      return;
    }
    final exited = Completer<void>();
    final onExit = ReceivePort()
      ..listen((_) {
        if (!exited.isCompleted) {
          exited.complete();
        }
      });
    iso.addOnExitListener(onExit.sendPort);
    await exited.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // A helper that survives an epoch interrupt is a wasmtime bug; the
        // supervisor's stop() kills the process as a backstop.
      },
    );
    onExit.close();
  }

  // -------------------------------------------------------------------------

  Future<void> teardownAndExit(int code) async {
    // Join all owned work, in dependency order: the live guest call (cut off
    // by an epoch bump, then joined on the helper isolate), the instance, the
    // module, the engine. wasmtime_store_delete blocks until the store's call
    // stack is gone; this is the "join" Phase 0 requires.
    if (callActive) {
      engine.bumpEpoch();
      await joinCallHelper();
    }
    instance?.close();
    instance = null;
    module?.close();
    module = null;
    engine.close();
    exit(code);
  }

  void handle(Map<String, Object?> req) {
        final id = req['id'] as int;
    switch (req['method'] as String) {
      case 'ping':
        ok(id, {'pong': true, 'pid': pid});
      case 'load':
        try {
          final bytes = base64Decode(req['bytes_base64'] as String);
          module = WasmtimeModule(engine, bytes);
          instance = WasmtimeInstance.instantiate(engine, module!);
          ok(id, {'loaded': true});
        } on WasmtimeException catch (e) {
          fail(id, e.message);
        } on ArgumentError catch (e) {
          fail(id, 'bad bytes: ${e.message}');
        }
      case 'call':
        final inst = instance;
        if (inst == null) {
          fail(id, 'no guest loaded');
          return;
        }
        if (callActive) {
          fail(id, 'a call is already in flight');
          return;
        }
        cancelled = false;
        callActive = true;
        final name = req['name'] as String;
        final argv = (req['args'] as List? ?? const []).cast<int>();
        runCallOnHelper(inst, name, argv).then((value) {
          callActive = false;
          ok(id, {'value': value});
        }).catchError((Object e) {
          callActive = false;
          fail(id, cancelled ? 'cancelled' : '$e');
        });
      case 'cancel':
        cancelled = true;
        // Cut the guest off at its next epoch check. The helper isolate is
        // inside wasmtime_func_call; the bump takes effect cross-thread.
        engine.bumpEpoch();
        ok(id, {'cancelling': true});
      case 'shutdown':
        ok(id, {'bye': true});
        unawaited(teardownAndExit(0));
      default:
        fail(id, 'unknown method: ${req['method']}');
    }
  }

  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    if (line.trim().isEmpty) {
      return;
    }
    try {
      final req = jsonDecode(line) as Map<String, Object?>;
      if (req['method'] == 'call' && instance != null) {
        // Arm the deadline before dispatching: the deadline is rebased on the
        // CURRENT epoch at arm time, so arming must happen on this (main)
        // isolate before the helper enters the guest — otherwise a cancel
        // that raced ahead would be swallowed by a later re-arm.
        instance!.setEpochDeadline(epochGrace);
      }
      handle(req);
    } on FormatException catch (e) {
      fail(-1, 'bad request line: ${e.message}');
    } on Object catch (e) {
      fail(-1, 'worker error: $e');
    }
  }, onDone: () {
    // Supervisor closed the pipe: join owned work and exit.
    unawaited(teardownAndExit(0));
  }, onError: (Object e) {
    fail(-1, 'stdin error: $e');
  });
}

/// One guest call, executed on a short-lived helper isolate so the worker's
/// main isolate stays free to bump the epoch for cancellation.
class _HelperMsg {
  _HelperMsg({
    required this.reply,
    required this.errors,
    required this.context,
    required this.instance,
    required this.name,
    required this.args,
  });

  final SendPort reply;
  final SendPort errors;
  final int context;
  final int instance;
  final String name;
  final List<int> args;
}

void _helperEntry(_HelperMsg m) {
  try {
    final r = WasmtimeInstance.callI32Raw(
      ffi.Pointer<ffi.Void>.fromAddress(m.context),
      ffi.Pointer<ffi.Uint8>.fromAddress(m.instance),
      m.name,
      m.args,
    );
    m.reply.send(r);
  } on Object catch (e) {
    m.errors.send(e);
  }
}

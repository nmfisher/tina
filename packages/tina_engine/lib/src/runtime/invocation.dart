import 'dart:async';
import 'dart:collection';

import 'contracts.dart';

/// A callable capability. Registration still owns dependency and resource life.
abstract interface class Component {
  String get id;
  String get name;
}

/// Identity adapter for existing typed agents, classifiers and handlers.
class ComponentInfo implements Component {
  @override
  final String id;
  @override
  final String name;
  const ComponentInfo(this.id, this.name);
}

enum InvocationState {
  queued,
  running,
  held,
  cancelling,
  completed,
  cancelled,
  failed
}

class InvocationCancelled implements Exception {
  final Object? reason;
  const InvocationCancelled([this.reason]);
  @override
  String toString() =>
      'Invocation cancelled${reason == null ? '' : ': $reason'}';
}

/// One call, distinct from the component instance and from the user input.
/// Use a qualified import where Dart's core Invocation is also needed.
class Invocation {
  final String id;
  final Component component;
  final String conversationId;
  final String? inputId;
  final Invocation? parent;
  final Invocations owner;
  final _cancel = Completer<void>();
  final _done = Completer<void>();
  final _listeners = <void Function()>{};
  final _holds = <Object>{};
  final _children = <Invocation>{};
  final _output = Queue<({void Function() deliver, int size})>();
  Completer<void> _changed = Completer<void>();
  bool _started = false;
  bool _failed = false;
  int _bufferSize = 0;
  Object? _reason;
  Invocation._(this.owner, this.id, this.component, this.conversationId,
      this.inputId, this.parent);

  Future<void> get cancelSignal => _cancel.future;
  Future<void> get done => _done.future;
  bool get isDone => _done.isCompleted;
  bool get isCancelled => _cancel.isCompleted;
  Object? get cancelReason => _reason;
  bool get isHeld => _holds.isNotEmpty || (parent?.isHeld ?? false);
  int get bufferedSize => _bufferSize;
  InvocationState get state => isDone
      ? isCancelled
          ? InvocationState.cancelled
          : _failed
              ? InvocationState.failed
              : InvocationState.completed
      : isCancelled
          ? InvocationState.cancelling
          : isHeld
              ? InvocationState.held
              : _started
                  ? InvocationState.running
                  : InvocationState.queued;

  /// Synchronous notifications ensure a hold closes dispatch before UI opens.
  void Function() listen(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notify() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
    for (final listener in _listeners.toList()) {
      try {
        listener();
      } catch (_) {/* UI listeners cannot break cancellation. */}
    }
    for (final child in _children.toList()) {
      child._notify();
      child._flush();
    }
  }

  /// Independent leases prevent one caller from releasing another's hold.
  Registration hold() {
    if (isDone || isCancelled) throw StateError('Invocation $id has stopped');
    final token = Object();
    _holds.add(token);
    _notify();
    return Registration.create('$id.hold', () {
      _holds.remove(token);
      try {
        _flush();
      } finally {
        _notify();
      }
    });
  }

  void cancel([Object? reason]) {
    if (isDone || isCancelled) return;
    _reason = reason;
    _cancel.complete();
    _output.clear();
    _bufferSize = 0;
    for (final child in _children.toList()) {
      child.cancel(reason);
    }
    _notify();
    if (!_started) _finish();
  }

  Future<void> ready() async {
    while (isHeld && !isCancelled) {
      await _changed.future;
    }
    if (isCancelled || isDone) throw InvocationCancelled(_reason);
  }

  /// Presentation only. Durable tool results must be recorded independently.
  /// Overflow cancels a producer that cannot apply flow control; it never
  /// silently drops output and then resumes an incomplete response.
  void output(void Function() deliver, {int size = 1}) {
    if (isCancelled || isDone) return;
    if (parent?.isHeld == true) {
      parent!.output(() {
        if (!isCancelled && !isDone) output(deliver, size: size);
      }, size: size);
      return;
    }
    if (!isHeld && _output.isEmpty) {
      deliver();
      return;
    }
    if (_bufferSize + size > owner.maxBufferedSize) {
      cancel('Output buffer limit reached while held');
      return;
    }
    final origin = Zone.current;
    _output.add((deliver: () => origin.run(deliver), size: size));
    _bufferSize += size;
  }

  void _flush() {
    while (!isHeld && !isCancelled && _output.isNotEmpty) {
      final item = _output.removeFirst();
      _bufferSize -= item.size;
      try {
        item.deliver();
      } catch (error) {
        cancel('Output delivery failed: $error');
      }
    }
  }

  Future<T> run<T>(FutureOr<T> Function(InvocationContext context) body) async {
    if (_started || isDone) throw StateError('Invocation $id already started');
    _started = true;
    final context = InvocationContext._(this);
    try {
      while (isHeld && !isCancelled) {
        await ready();
      }
      if (isCancelled) throw InvocationCancelled(_reason);
      final value = await runZoned(() => Future<T>.sync(() => body(context)),
          zoneValues: {InvocationContext._key: context});
      // The call stays alive while its provisional output awaits a decision.
      while (isHeld && !isCancelled) {
        await ready();
      }
      if (isCancelled) throw InvocationCancelled(_reason);
      return value;
    } catch (error) {
      _failed = error is! InvocationCancelled;
      rethrow;
    } finally {
      // Owned children cannot outlive their invocation.
      for (final child in _children.toList()) {
        child.cancel(_reason ?? 'Parent completed');
      }
      await Future.wait(_children.toList().map((child) => child.done));
      _finish();
    }
  }

  void _finish() {
    if (isDone) return;
    _done.complete();
    parent?._children.remove(this);
    owner._active.remove(id);
    _notify();
    _listeners.clear();
  }
}

/// Passed to new components explicitly. The zone bridge lets existing typed
/// drivers and tools participate without adding a generic invoke(Object) API.
class InvocationContext {
  static final _key = Object();
  static InvocationContext? get current =>
      Zone.current[_key] as InvocationContext?;
  final Invocation invocation;
  InvocationContext._(this.invocation);

  /// Work cannot outlive this scope, even after ordinary completion.
  Future<void> get cancelSignal =>
      Future.any([invocation.cancelSignal, invocation.done]);
  bool get isCancelled => invocation.isCancelled || invocation.isDone;
  Future<void> ready() => invocation.ready();
  Future<void>? stopSignal(Future<void>? other) =>
      other == null ? cancelSignal : Future.any([cancelSignal, other]);
}

/// Live calls only; completed handles remain usable by their caller, while the
/// registry does not retain transcripts or accumulate completed invocations.
class Invocations {
  final int maxBufferedSize;
  final _active = <String, Invocation>{};
  int _next = 0;
  bool _closed = false;
  Future<void>? _closing;
  Invocations({this.maxBufferedSize = 1024 * 1024});
  Iterable<Invocation> get active => List.unmodifiable(_active.values);
  Invocation create(
      {required Component component,
      required String conversationId,
      String? inputId,
      Invocation? parent}) {
    if (_closed) throw StateError('Invocation runtime is closed');
    if (parent != null &&
        (parent.owner != this ||
            parent.isDone ||
            parent.isCancelled ||
            parent.conversationId != conversationId)) {
      throw StateError('Invalid invocation parent');
    }
    final call = Invocation._(
        this, '${++_next}', component, conversationId, inputId, parent);
    _active[call.id] = call;
    parent?._children.add(call);
    return call;
  }

  Future<void> dispose() => _closing ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    final pending = active.toList();
    cancelAll(reason: 'Runtime disposed');
    await Future.wait(pending.map((call) => call.done));
  }

  void cancelAll({String? conversationId, Object? reason}) {
    for (final call in active) {
      if (conversationId == null || call.conversationId == conversationId)
        call.cancel(reason);
    }
  }
}

const invocationsServiceKey = ServiceKey<Invocations>('tina.invocations');

import 'dart:async';
import 'dart:convert';

import 'package:classifier/classification.dart' show freezeJson;
import 'package:tina_engine/tina_engine.dart';

/// A detached snapshot of one admitted user message. Plugins cannot mutate the
/// live conversation, its host, queue or driver through this context.
class InputContext {
  final String originalText;
  String _text;
  String get text => _text;

  /// Monotonic submission order within this input pipeline.
  final int order;
  String get id => '$order';
  Map<String, Object?> _data = const {};
  Map<String, Object?> get data => _data;
  final String conversationId;
  final List<Message> history;
  final _stop = Completer<void>();
  Object? _reason;
  final void Function(InputContext, int) _backgroundChanged;

  InputContext._(
    String text,
    this.conversationId,
    List<Message> history,
    Future<void> cancelSignal,
    this.order,
    this._backgroundChanged,
  ) : originalText = text,
      _text = text,
      history = List.unmodifiable(
        history.map(
          (message) => Message.fromJson(
            jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
          ),
        ),
      ) {
    cancelSignal.then(
      (_) => _cancel(const _InputCancelled()),
      onError: (Object _) => _cancel(const _InputCancelled()),
    );
  }

  Future<void> get cancelSignal => _stop.future;
  bool get isCancelled => _stop.isCompleted;

  /// Own background work without delaying forwarding. Cancellation releases
  /// host bookkeeping immediately; the work must observe cancelSignal itself.
  /// Report failures through the plugin's status, since they cannot fail a
  /// message that has already been forwarded.
  void background(Future<void> work) {
    _backgroundChanged(this, 1);
    Future.any<void>([work, cancelSignal]).then(
      (_) => _backgroundChanged(this, -1),
      onError: (Object _) => _backgroundChanged(this, -1),
    );
  }

  void _cancel(Object reason) {
    if (isCancelled) return;
    _reason = reason;
    _stop.complete();
  }

  /// The host races waits, so even an uncooperative plugin cannot strand input.
  /// Plugins must still stop their own requests/work when cancelSignal fires.
  Future<T> _wait<T>(FutureOr<T> Function() work) async {
    // Observe a signal that was already completed before this stage started.
    await Future<void>.value();
    if (isCancelled) throw _reason!;
    final value = await Future.any<T>([
      Future<T>.sync(work),
      cancelSignal.then<T>((_) => throw _reason!),
    ]);
    if (isCancelled) throw _reason!;
    return value;
  }
}

/// A named handler plus JSON data (for example, future classification labels).
/// The original user text is retained unchanged.
class InputRoute {
  final String handler;
  final Map<String, Object?> data;
  InputRoute(this.handler, {Map<String, Object?> data = const {}})
    : data = freezeJson(jsonDecode(jsonEncode(data))) as Map<String, Object?> {
    if (handler.trim().isEmpty) throw ArgumentError('Empty input handler');
  }
}

/// Return null to let the next router inspect the input. First match wins;
/// when all routers pass, the existing conversation agent receives the input.
abstract interface class InputRouter {
  Future<InputRoute?> route(InputContext input);
}

/// Registered under the contribution ID used by InputRoute.handler. Handlers
/// return a reply; the application owns presentation and transcript writes.
abstract interface class InputHandler {
  Future<String> handle(InputContext input, InputRoute route);
}

enum InputOutcome { pass, handled, failed, cancelled }

class _InputCancelled {
  const _InputCancelled();
}

/// A synchronous or asynchronous step before agent queue admission.
abstract interface class InputProcessor {
  FutureOr<InputDecision> process(InputContext input);
}

enum InputAction { pass, replace, route, stop }

class InputDecision {
  final InputAction action;
  final String? text;
  final InputRoute? destination;
  final Map<String, Object?> data;
  const InputDecision.pass({this.data = const {}})
    : action = InputAction.pass,
      text = null,
      destination = null;
  const InputDecision.replace(String text, {this.data = const {}})
    : action = InputAction.replace,
      text = text,
      destination = null;
  const InputDecision.route(InputRoute route, {this.data = const {}})
    : action = InputAction.route,
      destination = route,
      text = null;
  const InputDecision.stop()
    : action = InputAction.stop,
      text = null,
      destination = null,
      data = const {};
}

/// Prepared input is immutable to consumers; only the host may deliver it.
class PreparedInput {
  final InputContext context;
  final InputRoute? route;
  final InputOutcome outcome;
  final Object? error;
  final List<Contribution> _owners;
  PreparedInput._(
    this.context,
    this.outcome,
    this.route,
    this.error,
    this._owners,
  );
  String get text => context.text;
  String get originalText => context.originalText;
  void cancel() => context._cancel(const _InputCancelled());
}

/// Live pipeline contributions. Old InputRouters are supported as pass/route
/// processors. Selection is done before queuing; handlers run in turn order.
class InputRoutes {
  final PluginScope scope;
  final Duration timeout;
  int _nextId = 0;
  final _background = <InputContext, int>{};
  InputRoutes(this.scope, {this.timeout = const Duration(minutes: 5)}) {
    if (timeout <= Duration.zero) throw ArgumentError('Invalid input timeout');
  }

  bool get hasProcessors => scope.contributions.any(
    (c) => c.contribution is InputProcessor || c.contribution is InputRouter,
  );

  void _track(InputContext input, int delta) {
    final count = (_background[input] ?? 0) + delta;
    if (count <= 0) {
      _background.remove(input);
    } else {
      _background[input] = count;
    }
  }

  /// Includes work whose input has already passed through the agent queue.
  bool cancelBackground(String conversationId) {
    final pending = _background.keys
        .where((c) => c.conversationId == conversationId)
        .toList();
    for (final input in pending) {
      input._cancel(const _InputCancelled());
    }
    return pending.isNotEmpty;
  }

  void _check(Contribution owner) {
    if (!scope.isAdmitting || !scope.contributions.contains(owner)) {
      throw StateError('Input plugin ${owner.id} was removed');
    }
  }

  Future<T> _watch<T>(
    InputContext input,
    Contribution owner,
    FutureOr<T> Function() work, {
    List<Contribution> owners = const [],
  }) async {
    void check() {
      try {
        _check(owner);
        for (final previous in owners) {
          _check(previous);
        }
      } catch (e) {
        input._cancel(e);
      }
    }

    final changes = scope.changes.listen((_) => check(), onDone: check);
    try {
      check();
      final value = await input._wait(work);
      check();
      if (input.isCancelled) throw input._reason!;
      return value;
    } finally {
      await changes.cancel();
    }
  }

  Future<PreparedInput> prepare({
    required String text,
    required String conversationId,
    required List<Message> history,
    required Future<void> cancelSignal,
  }) async {
    final input = InputContext._(
      text,
      conversationId,
      history,
      cancelSignal,
      ++_nextId,
      _track,
    );
    final owners = <Contribution>[];
    final timer = Timer(
      timeout,
      () => input._cancel(
        TimeoutException('Input processing timed out', timeout),
      ),
    );
    try {
      if (!scope.isAdmitting) throw StateError('Input plugin scope is closed');
      for (final owner in scope.contributions) {
        final step = owner.contribution;
        if (step is! InputProcessor && step is! InputRouter) continue;
        owners.add(owner);
        final decision = await _watch(input, owner, () async {
          if (step is InputProcessor) return await step.process(input);
          final route = await (step as InputRouter).route(input);
          return route == null
              ? const InputDecision.pass()
              : InputDecision.route(route);
        }, owners: owners);
        input._data =
            freezeJson(
                  jsonDecode(jsonEncode({...input.data, ...decision.data})),
                )
                as Map<String, Object?>;
        switch (decision.action) {
          case InputAction.pass:
            break;
          case InputAction.replace:
            final replacement = decision.text;
            if (replacement == null || replacement.trim().isEmpty) {
              throw StateError(
                'Input processor returned empty text; use stop()',
              );
            }
            input._text = replacement;
          case InputAction.route:
            final route = decision.destination!;
            final handler = scope.contributions
                .where(
                  (c) =>
                      c.id == route.handler && c.contribution is InputHandler,
                )
                .firstOrNull;
            if (handler == null)
              throw StateError('Unknown input handler: ${route.handler}');
            owners.add(handler);
            return PreparedInput._(
              input,
              InputOutcome.pass,
              route,
              null,
              owners,
            );
          case InputAction.stop:
            return PreparedInput._(
              input,
              InputOutcome.handled,
              null,
              null,
              owners,
            );
        }
      }
      await input._wait(() {});
      return PreparedInput._(input, InputOutcome.pass, null, null, owners);
    } catch (e) {
      return PreparedInput._(
        input,
        e is _InputCancelled ? InputOutcome.cancelled : InputOutcome.failed,
        null,
        e,
        owners,
      );
    } finally {
      timer.cancel();
    }
  }

  /// Complete a selected handler or report processing errors in transcript
  /// order. Pass-through leaves recording to the agent as before.
  Future<InputOutcome> deliver(
    PreparedInput prepared, {
    required List<Message> history,
    required HostInterface host,
    required Future<void> cancelSignal,
    SessionRecorder? recorder,
  }) async {
    final input = prepared.context;
    var active = true;
    cancelSignal.then((_) {
      if (active) prepared.cancel();
    });
    final timer = Timer(
      timeout,
      () => input._cancel(TimeoutException('Input routing timed out', timeout)),
    );
    var recorded = false;
    Future<void> save(Message message) async {
      history.add(message);
      try {
        await recorder?.append(message);
      } catch (e) {
        host.showMessage(
          'session write failed: $e\n',
          style: HostMessageStyle.error,
        );
      }
    }

    Future<void> saveUser() async {
      if (recorded) return;
      recorded = true;
      await save(
        Message(role: Role.user, content: [TextBlock(input.originalText)]),
      );
    }

    try {
      if (prepared.error != null) throw prepared.error!;
      for (final owner in prepared._owners) {
        _check(owner);
      }
      await input._wait(() {});
      if (prepared.outcome == InputOutcome.handled) {
        return InputOutcome.handled;
      }
      final route = prepared.route;
      if (route == null) return InputOutcome.pass;
      final target = prepared._owners.last;
      await saveUser();
      final reply = await _watch(
        input,
        target,
        () => (target.contribution as InputHandler).handle(input, route),
        owners: prepared._owners,
      );
      if (reply.trim().isEmpty)
        throw StateError('Input handler returned an empty reply');
      await save(Message(role: Role.assistant, content: [TextBlock(reply)]));
      host.text(reply);
      host.newline();
      return InputOutcome.handled;
    } catch (e) {
      await saveUser();
      final cancelled = e is _InputCancelled;
      final notice = cancelled ? '[cancelled]' : '[input routing failed: $e]';
      await save(Message(role: Role.assistant, content: [TextBlock(notice)]));
      host.showMessage(
        '$notice\n',
        style: cancelled ? HostMessageStyle.dim : HostMessageStyle.error,
      );
      return cancelled ? InputOutcome.cancelled : InputOutcome.failed;
    } finally {
      active = false;
      timer.cancel();
      if (recorded && recorder != null) {
        try {
          await recorder.replace(history);
        } catch (e) {
          host.showMessage(
            'session write failed: $e\n',
            style: HostMessageStyle.error,
          );
        }
      }
    }
  }

  /// Compatibility convenience for callers that do not need transformed text.
  Future<InputOutcome> run({
    required String text,
    required String conversationId,
    required List<Message> history,
    required Future<void> cancelSignal,
    required HostInterface host,
    SessionRecorder? recorder,
  }) async {
    final prepared = await prepare(
      text: text,
      conversationId: conversationId,
      history: history,
      cancelSignal: cancelSignal,
    );
    return deliver(
      prepared,
      history: history,
      cancelSignal: cancelSignal,
      host: host,
      recorder: recorder,
    );
  }
}

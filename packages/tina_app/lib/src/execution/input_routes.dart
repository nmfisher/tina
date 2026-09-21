import 'dart:async';
import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';

/// A detached snapshot of one admitted user message. Plugins cannot mutate the
/// live conversation, its host, queue or driver through this context.
class InputContext {
  final String text;
  final String conversationId;
  final List<Message> history;
  final _stop = Completer<void>();
  Object? _reason;

  InputContext._(
    this.text,
    this.conversationId,
    List<Message> history,
    Future<void> cancelSignal,
  ) : history = List.unmodifiable(
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

  void _cancel(Object reason) {
    if (isCancelled) return;
    _reason = reason;
    _stop.complete();
  }

  /// The host races waits, so even an uncooperative plugin cannot strand input.
  /// Plugins must still stop their own requests/work when cancelSignal fires.
  Future<T> _wait<T>(Future<T> Function() work) async {
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
    : data = Map.unmodifiable(
        jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
      ) {
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

/// Live plugin contributions, in registration order. The registry owns plugin
/// lifetime; this service borrows it and keeps no separate registration cache.
class InputRoutes {
  final PluginScope scope;
  final Duration timeout;
  InputRoutes(this.scope, {this.timeout = const Duration(minutes: 5)}) {
    if (timeout <= Duration.zero) throw ArgumentError('Invalid input timeout');
  }

  /// Used by both the TUI turn runner and headless --prompt. This runs before
  /// compaction or any agent/model invocation. Failures never fall through to
  /// an unintended agent, and late plugin replies cannot write to the transcript.
  Future<InputOutcome> run({
    required String text,
    required String conversationId,
    required List<Message> history,
    required Future<void> cancelSignal,
    required HostInterface host,
    SessionRecorder? recorder,
  }) async {
    final routers = scope.contributions
        .where((c) => c.contribution is InputRouter)
        .toList();
    if (scope.isAdmitting && routers.isEmpty) return InputOutcome.pass;
    final input = InputContext._(text, conversationId, history, cancelSignal);
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
      await save(Message(role: Role.user, content: [TextBlock(text)]));
    }

    void checkLive(Contribution contribution) {
      if (!scope.isAdmitting || !scope.contributions.contains(contribution)) {
        throw StateError('Input plugin ${contribution.id} was removed');
      }
    }

    try {
      if (!scope.isAdmitting) throw StateError('Input plugin scope is closed');
      for (final router in routers) {
        checkLive(router);
        final route = await input._wait(
          () => (router.contribution as InputRouter).route(input),
        );
        checkLive(router);
        if (route == null) continue;
        final target = scope.contributions
            .where(
              (c) => c.id == route.handler && c.contribution is InputHandler,
            )
            .firstOrNull;
        if (target == null) {
          throw StateError('Unknown input handler: ${route.handler}');
        }
        await saveUser();
        final reply = await input._wait(
          () => (target.contribution as InputHandler).handle(input, route),
        );
        checkLive(target);
        if (reply.trim().isEmpty)
          throw StateError('Input handler returned an empty reply');
        await save(Message(role: Role.assistant, content: [TextBlock(reply)]));
        host.text(reply);
        host.newline();
        return InputOutcome.handled;
      }
      return InputOutcome.pass;
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
      timer.cancel();
      // Reconcile partial append failures just as ordinary agent turns do.
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
}

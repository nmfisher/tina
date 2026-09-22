import 'dart:async';
import 'package:classifier/judgments.dart';
import 'package:tina_engine/tina_engine.dart';
import '../classification/git_classifier.dart';
import 'input_routes.dart';
import 'input_status.dart';

enum GitPhase { checking, ready, unavailable, cancelled }

class GitStatus {
  final String inputId;
  final GitPhase phase;
  final GitIntent? intent;
  const GitStatus(this.inputId, this.phase, [this.intent]);
}

typedef GitCheck =
    Future<GitIntent?> Function(InputContext, JudgmentCancellation);

/// An example input/status plugin. In background mode only status is updated;
/// in awaited mode the result is also attached to input metadata before queuing.
class GitInput implements Component, InputProcessor, StatusSource {
  @override
  String get id => 'tina.git-input.status';
  @override
  String get name => 'Git classifier';
  final GitCheck classify;
  final bool background;
  final Duration timeout;
  final _values = <String, GitStatus>{};
  final _latest = <String, JudgmentCancellation>{};
  final _orders = <String, int>{};
  final _running = <JudgmentCancellation>{};
  final _changes = StreamController<void>.broadcast();
  bool _closed = false;
  GitInput(
    this.classify, {
    this.background = true,
    this.timeout = const Duration(seconds: 15),
  });
  @override
  Stream<void> get changes => _changes.stream;
  @override
  GitStatus? read(String conversationId) => _values[conversationId];

  @override
  FutureOr<InputDecision> process(InputContext input) {
    if (_closed) return const InputDecision.pass();
    final newest = input.order > (_orders[input.conversationId] ?? -1);
    if (background && !newest) return const InputDecision.pass();
    if (background) _latest[input.conversationId]?.cancel();
    final cancel = JudgmentCancellation();
    if (newest) {
      _orders[input.conversationId] = input.order;
      _latest[input.conversationId] = cancel;
    }
    _running.add(cancel);
    final invocation = input.invocation;
    void publish(GitPhase phase, [GitIntent? intent]) {
      void deliver() {
        if (_closed || !identical(_latest[input.conversationId], cancel))
          return;
        _values[input.conversationId] = GitStatus(input.id, phase, intent);
        _changes.add(null);
      }

      if (invocation == null || phase == GitPhase.cancelled) {
        deliver();
      } else {
        invocation.output(deliver);
      }
    }

    publish(GitPhase.checking);
    var finished = false;
    input.cancelSignal.then((_) {
      if (!finished) cancel.cancel();
      // A completed classification can still have its result held for display.
      if (invocation?.isCancelled == true) publish(GitPhase.cancelled);
    });
    final stopped = Completer<GitIntent?>();
    final detach = cancel.listen(() {
      if (!stopped.isCompleted) stopped.complete(null);
    });
    Future<InputDecision> work() async {
      final timer = Timer(timeout, cancel.cancel);
      try {
        final intent = await Future.any([
          Future<GitIntent?>.sync(() => classify(input, cancel)),
          stopped.future,
        ]);
        publish(
          input.isCancelled
              ? GitPhase.cancelled
              : intent == null
              ? GitPhase.unavailable
              : GitPhase.ready,
          intent,
        );
        return InputDecision.pass(
          data: intent == null ? const {} : {'git': intent.toJson()},
        );
      } catch (_) {
        publish(input.isCancelled ? GitPhase.cancelled : GitPhase.unavailable);
        return const InputDecision.pass();
      } finally {
        finished = true;
        timer.cancel();
        detach();
        _running.remove(cancel);
      }
    }

    final pending = work();
    if (!background) return pending;
    input.background(pending.then((_) {}));
    return const InputDecision.pass();
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    for (final token in _running.toList()) {
      token.cancel();
    }
    _values.clear();
    _latest.clear();
    _orders.clear();
    await _changes.close();
  }
}

PluginDescriptor gitInputPlugin({
  required GitCheck classify,
  bool background = true,
}) => PluginDescriptor(
  id: 'tina.git-input',
  factory: FnPluginFactory((context) {
    final plugin = GitInput(classify, background: background);
    context.register(plugin, dispose: plugin.dispose);
    return plugin;
  }),
);

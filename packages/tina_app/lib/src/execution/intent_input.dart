import 'dart:async';
import 'package:classifier/judgments.dart';
import 'package:tina_engine/tina_engine.dart';
import '../classification/intent_classifier.dart';
import 'input_routes.dart';
import 'input_status.dart';

enum IntentPhase { checking, ready, unavailable, cancelled }

class IntentStatus {
  final String inputId;
  final IntentPhase phase;
  final IntentResult? result;
  const IntentStatus(this.inputId, this.phase, [this.result]);
}

typedef IntentCheck =
    Future<IntentResult?> Function(InputContext, JudgmentCancellation);

class IntentInput implements Component, InputProcessor, StatusSource {
  @override
  String get id => 'tina.intent-input.status';
  @override
  String get name => 'Intent classifier';
  final IntentCheck classify;
  final bool background;
  final Duration timeout;
  final _values = <String, IntentStatus>{};
  final _latest = <String, JudgmentCancellation>{};
  final _orders = <String, int>{};
  final _running = <JudgmentCancellation>{};
  final _changes = StreamController<void>.broadcast();
  bool _closed = false;
  IntentInput(
    this.classify, {
    this.background = true,
    this.timeout = const Duration(seconds: 15),
  });
  @override
  Stream<void> get changes => _changes.stream;
  @override
  IntentStatus? read(String conversationId) => _values[conversationId];

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
    void publish(IntentPhase phase, [IntentResult? result]) {
      void deliver() {
        if (_closed || !identical(_latest[input.conversationId], cancel)) return;
        _values[input.conversationId] = IntentStatus(input.id, phase, result);
        _changes.add(null);
      }
      if (invocation == null || phase == IntentPhase.cancelled) {
        deliver();
      } else {
        invocation.output(deliver);
      }
    }
    publish(IntentPhase.checking);
    var finished = false;
    input.cancelSignal.then((_) {
      if (!finished) cancel.cancel();
      if (invocation?.isCancelled == true) publish(IntentPhase.cancelled);
    });
    final stopped = Completer<IntentResult?>();
    final detach = cancel.listen(() {
      if (!stopped.isCompleted) stopped.complete(null);
    });
    Future<InputDecision> work() async {
      final timer = Timer(timeout, cancel.cancel);
      try {
        final result = await Future.any([
          Future<IntentResult?>.sync(() => classify(input, cancel)),
          stopped.future,
        ]);
        publish(
          input.isCancelled
              ? IntentPhase.cancelled
              : result == null
                  ? IntentPhase.unavailable
                  : IntentPhase.ready,
          result,
        );
        return InputDecision.pass(
          data: result == null ? const {} : {'intent': result.toJson()},
        );
      } catch (_) {
        publish(input.isCancelled ? IntentPhase.cancelled : IntentPhase.unavailable);
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

PluginDescriptor intentInputPlugin({
  required IntentCheck classify,
  bool background = true,
}) => PluginDescriptor(
      id: 'tina.intent-input',
      factory: FnPluginFactory((context) {
        final plugin = IntentInput(classify, background: background);
        context.register(plugin, dispose: plugin.dispose);
        return plugin;
      }),
    );

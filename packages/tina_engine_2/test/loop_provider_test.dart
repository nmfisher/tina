// Provider replacement boundaries: immediate while idle, deferred while
// between-turns work owns the loop (compaction), refused inside a turn.
//
// Run: dart test
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// A provider that counts closes and answers nothing — enough to pin who
/// owns the request resource and when the old one is retired.
final class _Provider implements LlmProvider {  _Provider(this.name);
  final String name;
  int closes = 0;

  @override
  String get model => name;

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {}

  @override
  void close() => closes++;
}

/// The loop's turn pipeline wants at least one plugin to complete
/// preparation; a no-op keeps the focus on the provider boundary.
final class _NoopPlugin extends AgentPlugin {
  @override
  String get id => 'test/noop';
}

/// Holds designated scripted replies mid-stream so a test can act while
/// the loop owns an in-flight request.
final class _GatedProvider implements LlmProvider {
  _GatedProvider(this.inner, {required this.holdAt});
  final ScriptedProvider inner;
  final int holdAt;
  final started = Completer<void>();
  Completer<void>? _release;

  @override
  String get model => inner.model;

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    if (inner.requests.length == holdAt) {
      _release = Completer<void>();
      started.complete();
      await _release!.future;
    }
    yield* inner.send(system: system, messages: messages, tools: tools);
  }

  void release() => _release?.complete();

  @override
  void close() => inner.close();
}

void main() {
  test('idle replacement swaps immediately and closes the old provider', () {
    final loop = AgentLoop(provider: _Provider('old'), plugins: const []);
    final next = _Provider('new');
    loop.replaceProvider(next);
    expect(loop.provider, same(next));
    expect((loop.provider as _Provider).closes, 0);
  });

  test('a replacement during between-turns work installs when the work ends',
      () async {
    final old = _Provider('old');
    final loop = AgentLoop(provider: old, plugins: const []);
    final inside = Completer<void>(), held = Completer<void>();
    final operation = loop.betweenTurns(() async {
      inside.complete();
      await held.future;
    });
    await inside.future;
    final next = _Provider('next');
    loop.replaceProvider(next); // queued, not applied, nothing closed
    expect(loop.provider, same(old));
    expect(old.closes, 0,
        reason: 'the running work keeps the provider it started with');
    expect(next.closes, 0);
    held.complete();
    await operation;
    expect(loop.provider, same(next));
    expect(old.closes, 1, reason: 'retired at the boundary, never before');
  });

  test('a superseded queued replacement is closed unused', () async {
    final loop = AgentLoop(provider: _Provider('old'), plugins: const []);
    final inside = Completer<void>(), held = Completer<void>();
    final operation = loop.betweenTurns(() async {
      inside.complete();
      await held.future;
    });
    await inside.future;
    final first = _Provider('first'), second = _Provider('second');
    loop.replaceProvider(first);
    loop.replaceProvider(second);
    held.complete();
    await operation;
    expect(loop.provider, same(second));
    expect(first.closes, 1, reason: 'never installed, still retired');
    expect(second.closes, 0);
  });

  test('a replacement inside a running turn is refused', () async {
    final gated = _GatedProvider(ScriptedProvider([scriptedReply('reply')]),
        holdAt: 0);
    final loop = AgentLoop(provider: gated, plugins: [_NoopPlugin()]);
    final outcome = loop.runTurn(const Input('go', id: 't'));
    await gated.started.future; // the turn's request is in flight
    expect(() => loop.replaceProvider(_Provider('other')), throwsStateError);
    gated.release();
    await outcome;
    // Idle again: a replacement now lands immediately.
    final next = _Provider('next');
    loop.replaceProvider(next);
    expect(loop.provider, same(next));
  });
}

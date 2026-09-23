import 'dart:async';

import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import 'package:tina/session_commands/session_command_handlers.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Minimal [Agent] for review tests — never runs a turn.
Agent _fakeAgent(LlmProvider provider, FakeHostInterface host) => Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: host,
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      system: '',
    );

/// A [CommandContext] for `/classifier-review` dispatch: the members this
/// command (and the dispatcher) touch are explicit; everything else throws
/// through [noSuchMethod], so an unexpected new access fails loudly.
class _ReviewCtx implements CommandContext {
  _ReviewCtx(this.conversation, {this.cancelSignal});

  final Conversation conversation;

  /// Null (the default) = no ESC wiring, as a bare dispatch has.
  final Future<void>? cancelSignal;

  @override
  Conversation get active => conversation;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  @override
  Future<void>? get commandCancelSignal => cancelSignal;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A non-adapter driver so the conversation resolves to the agent-less
/// sentinel — the driver-only shape `/classifier-review` must refuse.
class _ScriptedDriver implements AgentDriver {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final List<Message> _defaultHistory = [
  const Message(role: Role.user, content: [TextBlock('do the thing')]),
  const Message(role: Role.assistant, content: [TextBlock('done')]),
];

({
  Conversation conv,
  FakeHostInterface host,
  _ReviewCtx ctx,
  FakeProvider provider,
})
_fixture({
  List<Message>? history,
  FakeProvider? provider,
  PermissionPolicy? policy,
}) {
  final host = FakeHostInterface();
  final p = provider ?? FakeProvider.always(model: 'test-model');
  final conv = Conversation(
    id: 'test-conv',
    label: 'test-model',
    agent: _fakeAgent(p, host),
    provider: p,
    host: host,
    policy: policy ?? PermissionPolicy(),
    initialHistory: history ?? _defaultHistory,
  );
  return (conv: conv, host: host, ctx: _ReviewCtx(conv), provider: p);
}

/// The review question of the last provider call, as plain text.
String _questionOf(FakeProvider provider) =>
    (provider.calls.single.messages.last.content.single as TextBlock).text;

/// Notices that report a failed review (none should appear on success).
Iterable<String> _failures(FakeHostInterface host) => host.notices
    .where((n) => n.startsWith('classifier review failed'));

void main() {
  group('/classifier-review request shape', () {
    test('fresh context: review prompt, no tools, history as data',
        () async {
      final history = [
        const Message(role: Role.user, content: [TextBlock('user asks')]),
        const Message(
            role: Role.assistant, content: [TextBlock('assistant answers')]),
        Message(
          role: Role.assistant,
          content: const [],
          reasoning: const [ReasoningBlock('thinking aloud')],
        ),
      ];
      final f = _fixture(history: history);
      final before = List<Message>.of(f.conv.history);

      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');

      expect(f.provider.calls, hasLength(1));
      final call = f.provider.calls.single;
      expect(call.system, kClassifierReviewSystemPrompt,
          reason: 'a fresh context — the review prompt, not the '
              "conversation's own");
      expect(call.tools, isEmpty, reason: 'a review never gets tools');
      expect(call.messages, hasLength(3),
          reason: 'history minus reasoning-only, plus the review question');
      expect(identical(call.messages[0], history[0]), isTrue,
          reason: 'history passes as data — same instances');
      expect(identical(call.messages[1], history[1]), isTrue);
      expect(call.messages, isNot(contains(history[2])),
          reason: 'a reasoning-only message would send as an empty API '
              'message — it is dropped');

      final question = call.messages.last;
      expect(question.role, Role.user);
      final text = _questionOf(f.provider);
      expect(text, contains('Session context:'));
      expect(text, contains('- model: test-model'));
      expect(text, contains('- messages: 3'));
      expect(text, contains('- permission mode: ask'));
      expect(text, contains('- configured rules: none'));
      expect(text, contains('- remembered approvals: none'));
      expect(text, contains('report TypeSafe question candidates'));

      expect(f.conv.history, hasLength(before.length),
          reason: 'the review never mutates history');
      for (var i = 0; i < before.length; i++) {
        expect(identical(f.conv.history[i], before[i]), isTrue);
      }
      expect(_failures(f.host), isEmpty,
          reason: "FakeProvider.always completes without deltas — the "
              'MessageComplete fallback must render it, not fail');
    });

    test('the prompt pins the question shapes, the discriminator, and the '
        'domains', () {
      final p = kClassifierReviewSystemPrompt;
      // The three primitives, with their hard limits, stated exactly.
      expect(p, contains('choice: one of 1–255 named options'));
      expect(p, contains('score: a position on 2–10 ordered levels'));
      expect(p, contains('noul: the probability of yes'));
      expect(p, contains('Question ids are flat_snake'));
      expect(p, contains('AT the decision moment'));
      // The transcript is data, not instructions.
      expect(p, contains('DATA to review'));
      // Rule-vs-judgment: a deterministic rule or existing mechanism is not
      // a candidate.
      expect(p, contains('Rules are for what is certain'));
      // The domains the review must span.
      expect(p, contains('tool approvals:'));
      expect(p, contains('repository structure:'));
      expect(p, contains('commit messages and other artifacts'));
      expect(p, contains('test sufficiency'));
      // Every candidate names its caller; empty must be sayable.
      expect(p, contains('every candidate names its caller'));
      expect(p, contains('an empty result is a valid'));
    });

    test('the session header carries mode, rules, and remembered approvals',
        () async {
      final policy = PermissionPolicy(
        mode: PermissionMode.auto,
        rules: const [
          PermissionRule(
              toolName: 'bash',
              pattern: 'git status',
              decision: PermissionDecision.allow),
        ],
      );
      policy.remember('bash', 'git push', PermissionDecision.allow,
          source: GrantSource.classifier);
      final f = _fixture(policy: policy);

      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');

      final text = _questionOf(f.provider);
      expect(text, contains('- permission mode: auto'));
      expect(text, contains('- configured rules (1):'));
      expect(text, contains('  allow: bash:git status'));
      expect(text, contains('- remembered approvals (1):'),
          reason: 'grants are sink output, never history — this listing is '
              'the only record of what was prompted');
      expect(text, contains('  allow: bash:git push'));
      expect(text, contains('classifier'), reason: 'who answered rides along');
    });
  });

  group('/classifier-review arguments and guards', () {
    test('a focus argument narrows the review question', () async {
      final f = _fixture();
      await SessionCommandHandlers(f.ctx)
          .dispatch('/classifier-review commit messages');
      expect(_questionOf(f.provider), contains('focusing on: commit messages'));
    });

    test('without focus the question carries no narrowing clause', () async {
      final f = _fixture();
      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');
      expect(_questionOf(f.provider), isNot(contains('focusing on:')));
    });

    test('an oversized focus prints usage and never calls the provider',
        () async {
      final f = _fixture();
      final result = await SessionCommandHandlers(f.ctx).dispatch(
          '/classifier-review ${'x' * (kClassifierReviewMaxFocus + 1)}');
      expect(result, isA<CmdHandled>());
      expect(f.provider.calls, isEmpty);
      expect(f.host.styledMessages.last.style, HostMessageStyle.error);
      expect(f.host.styledMessages.last.message,
          'Usage: /classifier-review [focus, up to 2000 characters]\n');
    });

    test('empty history reports and never calls the provider', () async {
      final f = _fixture(history: const []);
      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');
      expect(f.provider.calls, isEmpty);
      expect(f.host.notices, contains('(nothing to review)\n'));
    });

    test('a driver-only conversation warns instead of crashing', () async {
      final host = FakeHostInterface();
      final provider = FakeProvider.always(model: 'test-model');
      final conv = Conversation(
        id: 'scripted',
        label: 'scripted',
        provider: provider,
        host: host,
        policy: PermissionPolicy(),
        driver: _ScriptedDriver(),
        initialHistory: _defaultHistory,
      );
      expect(conv.hasAgent, isFalse);

      await SessionCommandHandlers(_ReviewCtx(conv))
          .dispatch('/classifier-review');

      expect(provider.calls, isEmpty,
          reason: '_NullProvider would throw on send — the guard must not '
              'reach it');
      expect(_failures(host), isEmpty);
      expect(host.styledMessages.last.style, HostMessageStyle.warning);
      expect(host.styledMessages.last.message,
          contains('no live model in this conversation'));
    });

    test('an oversized request is refused by the budget before any send',
        () async {
      final f = _fixture();
      f.conv.agent.budget = TokenBudget(perRequestInputLimit: 5);

      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');

      expect(f.provider.calls, isEmpty);
      expect(f.host.notices, hasLength(1),
          reason: 'the pre-flight fails alone — no start marker is printed');
      expect(f.host.notices.single,
          startsWith('classifier review failed: request input estimate'));
      expect(f.host.notices.single, contains('exceeds --max-request-tokens'));
    });
  });

  group('/classifier-review streaming', () {
    test('streams the review into the transcript and closes the line',
        () async {
      final provider = FakeProvider([
        [
          const TextDelta('### '),
          const TextDelta('candidate one'),
          const MessageComplete(
              content: [TextBlock('### candidate one')],
              stopReason: 'end_turn'),
        ],
      ], model: 'test-model');
      final f = _fixture(provider: provider);

      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');

      expect(f.host.sink.texts.join(), '### candidate one');
      expect(f.host.sink.newlines, 1);
      expect(f.host.notices, ['--- classifier review: 2 messages ---\n'],
          reason: 'start marker only — success prints nothing extra');
      expect(f.host.activitySignals, [true, false],
          reason: 'the activity cue lifts on start and drops on every exit');
    });

    test('a one-event completion renders without deltas', () async {
      final provider = FakeProvider([
        [
          const MessageComplete(
              content: [TextBlock('review without deltas')],
              stopReason: 'end_turn'),
        ],
      ], model: 'test-model');
      final f = _fixture(provider: provider);

      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');

      expect(f.host.sink.texts.join(), 'review without deltas');
      expect(_failures(f.host), isEmpty);
      expect(f.host.sink.newlines, 1);
    });

    test('a stream error surfaces as a failed review, keeping partial text',
        () async {
      final provider = FakeProvider([
        [const TextDelta('partial '), const StreamError('boom')],
      ], model: 'test-model');
      final f = _fixture(provider: provider);

      await SessionCommandHandlers(f.ctx).dispatch('/classifier-review');

      expect(f.host.sink.texts.join(), 'partial ');
      expect(f.host.notices.last, 'classifier review failed: boom\n');
      expect(f.host.sink.notices.last.kind, NoticeKind.error);
      expect(f.host.activitySignals, [true, false],
          reason: 'the activity cue drops on the error path too');
    });

    test('an already-fired cancel signal settles without an error notice',
        () async {
      final f = _fixture();
      final ctx = _ReviewCtx(f.conv, cancelSignal: Future<void>.value());

      await SessionCommandHandlers(ctx).dispatch('/classifier-review');

      expect(_failures(f.host), isEmpty,
          reason: 'cancellation is silent, like /compact');
      expect(f.conv.history, hasLength(2),
          reason: 'review never mutates history, cancelled or not');
      expect(f.host.activitySignals, [true, false],
          reason: 'the activity cue drops on the cancel path too');
    });
  });
}

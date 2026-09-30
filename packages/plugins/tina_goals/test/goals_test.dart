// The goals plugin: the user's stated objective, injected into every
// request and judged after each completed turn. The tests pin the three
// moving parts and the truth: the GoalChangedEntry on the log (the entry
// IS the goal — a resume replays it), the <current-goal> section, the
// /goal command through the terminal, and the judge — one extra
// provider request, fired only after a *complete* turn, its VERDICT
// line parsed and recorded only when it says something new.
//
// Run: dart test
library;

import 'package:tina_persistence/tina_persistence.dart';
import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_goals/tina_goals.dart';
import 'package:test/test.dart';

final class _CaptureTerminal implements Terminal {
  final lines = <String>[];

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) async => '';
}

(AgentLoop, GoalsPlugin, ScriptedProvider) _wired({
  ScriptedProvider? provider,
  GoalsPlugin? plugin,
  Terminal? terminal,
}) {
  final p0 = provider ?? ScriptedProvider([]);
  final p = plugin ?? GoalsPlugin(terminal: terminal);
  final loop = AgentLoop(provider: p0, plugins: [p]);
  p.mountOn(loop);
  return (loop, p, p0);
}

List<String> _sections(AgentLoop loop, GoalsPlugin plugin) {
  final ctx = TurnContext(
    CancelToken(),
    input: const Input('probe', id: 'probe'),
    pinnedTools: const [],
    messages: const [],
    promptSections: [],
  );
  plugin.onPrompt(ctx);
  return List.of(ctx.promptSections);
}

/// Settle the judge's fire-and-forget future.
Future<void> settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
      '/goal sets the goal; the entry is on the log; the section '
      'follows', () async {
    final terminal = _CaptureTerminal();
    final (loop, plugin, _) = _wired(terminal: terminal);

    await plugin.commands.single.handler('ship the parser rewrite');
    expect(terminal.lines.last, contains('Goal: ship the parser rewrite'));
    expect(terminal.lines.last, contains('not judged yet'));

    final entry = loop.log
        .whereType<PluginStateEntry>()
        .where(GoalChangedEntry.matches)
        .map(GoalChangedEntry.decode)
        .single;
    expect(entry.text, 'ship the parser rewrite');
    expect(entry.verdict, GoalVerdict.none);

    final section = _sections(loop, plugin).single;
    expect(section, startsWith('<current-goal>'));
    expect(section, contains('Goal: ship the parser rewrite'));
    expect(section, endsWith('</current-goal>\n'));

    // No goal, no section: an empty goal is noise, not a statement.
    await plugin.commands.single.handler('clear');
    expect(terminal.lines.last, 'Goal cleared.');
    expect(_sections(loop, plugin), isEmpty);
    expect(
        loop.log
            .whereType<PluginStateEntry>()
            .where(GoalChangedEntry.matches)
            .map(GoalChangedEntry.decode)
            .last
            .text,
        isEmpty);
  });

  test('the goal survives a store round trip: a resumed host derives it',
      () async {
    final ws = await Directory.systemTemp.createTemp('tina_goals_ws_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final storePath = '${ws.path}/session.db';

    final startedPlugin = GoalsPlugin();
    final started = Host.start(HostConfig(
      providerFactory: (_) => ScriptedProvider([]),
      workingDirectory: ws.path,
      plugins: [
        startedPlugin,
        PersistencePlugin(openStore: () => SessionStore.open(storePath)),
      ],
    ));
    await started.session.loop.runTurn(const Input('go', id: 't1'));
    started.session.loop.stateWriter('tina/goals')(const GoalChangedEntry(
        text: 'land slice five',
        verdict: GoalVerdict.achieved,
        evidence: 'the suite is green'));
    final sessionId = started.session.id;
    started.close();

    final resumed = Host.resume(
      HostConfig(
        providerFactory: (_) => ScriptedProvider([]),
        workingDirectory: ws.path,
        plugins: [
          GoalsPlugin(),
          PersistencePlugin(openStore: () => SessionStore.open(storePath)),
        ],
      ),
      sessionId,
    );
    final view = resumed.session.loop.derive();
    expect(view.goal, isNotNull);
    expect(view.goal!.text, 'land slice five');
    expect(view.goal!.verdict, GoalVerdict.achieved);
    resumed.close();
  });

  test(
      'the judge fires after a complete turn, parses the VERDICT line, '
      'and records the entry', () async {
    final big = 'x' * 200;
    final provider = ScriptedProvider([
      scriptedReply(big),
      // The judge's reply:
      scriptedReply('VERDICT: yes — the parser tests pass and the CLI '
          'reads the new grammar'),
    ]);
    final (loop, plugin, _) = _wired(provider: provider);
    loop.stateWriter('tina/goals')(
        const GoalChangedEntry(text: 'land slice five'));

    await loop.runTurn(const Input('do the work', id: 't1'));
    await settle();

    // The judge request: the fixed prompt, no tools, goal plus digest.
    expect(provider.callCount, 2);
    final judgeRequest = provider.requests.last;
    expect(judgeRequest.systemPrompt, goalJudgeSystemPrompt);
    expect(judgeRequest.tools, isEmpty);
    expect((judgeRequest.messages.single.content.single as TextBlock).text,
        contains('GOAL: land slice five'));
    expect((judgeRequest.messages.single.content.single as TextBlock).text,
        contains('do the work'));

    final verdicts = loop.log
        .whereType<PluginStateEntry>()
        .where(GoalChangedEntry.matches)
        .map(GoalChangedEntry.decode)
        .toList();
    expect(verdicts, hasLength(2));
    expect(verdicts.last.verdict, GoalVerdict.achieved);
    expect(verdicts.last.evidence, contains('parser tests pass'));
    expect(plugin.goal!.isAchieved, isTrue);
    expect(_sections(loop, plugin).single, contains('ACHIEVED'));
  });

  test(
      'an errored or cancelled turn is not evidence: no judge request '
      'fires', () async {
    final provider = ScriptedProvider([
      [const StreamError('provider down')],
    ]);
    final (loop, plugin, _) = _wired(provider: provider);
    loop.stateWriter('tina/goals')(
        const GoalChangedEntry(text: 'the objective'));

    await loop.runTurn(const Input('go', id: 't1'));
    await settle();
    expect(provider.callCount, 1,
        reason: 'only the failed turn itself; no judge call');
    expect(plugin.goal!.verdict, GoalVerdict.none);

    // A cancelled turn likewise judges nothing: the turn is stopped
    // before the model call, and its end entry says cancelled.
    final provider2 = ScriptedProvider([scriptedReply('partial')]);
    final plugin2 = GoalsPlugin();
    final loop2 = AgentLoop(provider: provider2, plugins: [plugin2]);
    plugin2.mountOn(loop2);
    loop2.subscribe((entry, event) {
      if (entry is TurnStartedEntry) loop2.cancel('operator said stop');
    });
    loop2.stateWriter('tina/goals')(
        const GoalChangedEntry(text: 'the objective'));
    final outcome = await loop2.runTurn(const Input('go', id: 't1'));
    expect(outcome.stopReason, StopReason.cancelled);
    await settle();
    expect(provider2.callCount, 0,
        reason: 'cancelled before the model call; no judge either');
  });

  test(
      'a failed or unparsable judge answer records nothing and the '
      'next complete turn tries again', () async {
    final big = 'x' * 200;
    final provider = ScriptedProvider([
      scriptedReply(big),
      [const StreamError('judge down')],
      scriptedReply(big),
      scriptedReply('I am not sure what you want from me, sorry!'),
      scriptedReply(big),
      scriptedReply('VERDICT: no — the work visibly continues'),
    ]);
    final (loop, plugin, _) = _wired(provider: provider);
    loop.stateWriter('tina/goals')(
        const GoalChangedEntry(text: 'the objective'));

    await loop.runTurn(const Input('one', id: 't1'));
    await settle();
    expect(
        loop.log
            .whereType<PluginStateEntry>()
            .where(GoalChangedEntry.matches)
            .map(GoalChangedEntry.decode),
        hasLength(1),
        reason: 'a failed judge call records nothing');

    await loop.runTurn(const Input('two', id: 't2'));
    await settle();
    expect(
        loop.log
            .whereType<PluginStateEntry>()
            .where(GoalChangedEntry.matches)
            .map(GoalChangedEntry.decode),
        hasLength(1),
        reason: 'an unparsable answer records nothing either');

    await loop.runTurn(const Input('three', id: 't3'));
    await settle();
    final verdicts = loop.log
        .whereType<PluginStateEntry>()
        .where(GoalChangedEntry.matches)
        .map(GoalChangedEntry.decode)
        .toList();
    expect(verdicts, hasLength(2));
    expect(verdicts.last.verdict, GoalVerdict.inProgress);
  });

  test('an unchanged verdict is not re-recorded; a flip is', () async {
    final big = 'x' * 200;
    final provider = ScriptedProvider([
      scriptedReply(big),
      scriptedReply('VERDICT: yes — done'),
      scriptedReply(big),
      scriptedReply('VERDICT: yes — done'),
      scriptedReply(big),
      scriptedReply('VERDICT: unclear — the evidence is ambiguous'),
    ]);
    final (loop, _, _) = _wired(provider: provider);
    loop.stateWriter('tina/goals')(
        const GoalChangedEntry(text: 'the objective'));

    await loop.runTurn(const Input('one', id: 't1'));
    await settle();
    expect(
        loop.log
            .whereType<PluginStateEntry>()
            .where(GoalChangedEntry.matches)
            .map(GoalChangedEntry.decode),
        hasLength(2));

    await loop.runTurn(const Input('two', id: 't2'));
    await settle();
    expect(
        loop.log
            .whereType<PluginStateEntry>()
            .where(GoalChangedEntry.matches)
            .map(GoalChangedEntry.decode),
        hasLength(2),
        reason: 'the judge agreeing with itself appends nothing');

    await loop.runTurn(const Input('three', id: 't3'));
    await settle();
    final verdicts = loop.log
        .whereType<PluginStateEntry>()
        .where(GoalChangedEntry.matches)
        .map(GoalChangedEntry.decode)
        .toList();
    expect(verdicts, hasLength(3));
    expect(verdicts.last.verdict, GoalVerdict.uncertain);
  });

  test(
      'the digest caps itself and never mistakes a compaction summary '
      'for a user turn', () {
    final messages = [
      for (var i = 0; i < 40; i++)
        Message(role: Role.user, content: [TextBlock('turn $i ${'y' * 100}')]),
    ];
    final digest = GoalJudgeDigest.build(messages);
    expect(digest.length, lessThan(GoalJudgeDigest.maxChars + 100));
    expect(digest.split('\n'), hasLength(GoalJudgeDigest.maxMessages));

    final withSummary = [
      Message(
          role: Role.user,
          isSynthetic: true,
          content: [TextBlock('[earlier conversation summarized] stuff')]),
      Message(role: Role.user, content: [TextBlock('the real ask')]),
    ];
    final d2 = GoalJudgeDigest.build(withSummary);
    expect(d2, contains('the real ask'));
    expect(d2, isNot(contains('[earlier conversation summarized]')));
  });

  test('the entry round trips the store bytes, and junk is refused', () {
    const entry = GoalChangedEntry(
        text: 'the objective',
        verdict: GoalVerdict.uncertain,
        evidence: 'mixed signals');
    final back = GoalChangedEntry.decode(
        SessionEntry.fromJson(entry.toJson()..remove('seq'))
            as PluginStateEntry);
    expect(back, entry);

    expect(
        () => SessionEntry.fromJson({
              'type': 'goal_changed',
              'verdict': 'achieved',
            }),
        throwsA(isA<FormatException>()));
    expect(
        () => SessionEntry.fromJson({
              'type': 'goal_changed',
              'text': 'x',
              'verdict': 'sideways',
            }),
        throwsA(isA<FormatException>()));
  });

  test('/goal check judges on demand and shows the verdict', () async {
    final terminal = _CaptureTerminal();
    final provider = ScriptedProvider([
      scriptedReply('VERDICT: yes — the transcript shows completion'),
    ]);
    final plugin = GoalsPlugin(terminal: terminal);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    plugin.mountOn(loop);

    await plugin.commands.single.handler('the objective');
    await plugin.commands.single.handler('check');
    await settle();

    expect(provider.callCount, 1,
        reason: 'the check is the judge call; no turn ran');
    expect(terminal.lines.any((l) => l.contains('verdict: ACHIEVED')), isTrue);
    expect(terminal.lines.any((l) => l.contains('evidence:')), isTrue);
  });
}

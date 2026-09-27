// The plans plugin: the tracked task list the agent maintains with the
// update_plan tool. The tests pin the three surfaces and the truth:
// every change lands as a PlanChangedEntry on the log (the entry IS the
// plan — the latest wins, a resume replays it), the model-facing section
// renders the state and the approval posture, the /plan command edits
// and answers through the terminal, and a `requested` plan is put to the
// same Approver seam the sandbox's file asks use.
//
// Run: dart test
library;

import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

/// A capturing terminal — the same shape the mode command's tests use.
final class _CaptureTerminal implements Terminal {
  final lines = <String>[];
  final asks = <String>[];

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) async {
    asks.add(prompt);
    return '';
  }
}

/// A loop over a scripted provider with the plans plugin mounted — the
/// minimal wiring every test starts from.
(AgentLoop, PlansPlugin, ScriptedProvider) _wired({
  Approver? approver,
  Services? services,
}) {
  final provider = ScriptedProvider([]);
  final plugin = PlansPlugin(services: services, approver: approver);
  final loop = AgentLoop(provider: provider, plugins: [plugin]);
  plugin.mountOn(loop);
  return (loop, plugin, provider);
}

void main() {
  test('update_plan writes a PlanChangedEntry; the store replays the log',
      () async {
    final (loop, plugin, provider) = _wired();
    await loop.runTurn(const Input('plan it', id: 't1'));
    provider.requests.clear();

    final result = await _call(
        loop, plugin, {
      'items': [
        {'text': 'survey', 'state': 'done'},
        {'text': 'implement', 'state': 'in_progress'},
        {'text': 'verify', 'state': 'pending'},
      ],
    });
    expect(result.isError, isFalse, reason: result.content);

    final entries =
        loop.log.whereType<PlanChangedEntry>().toList();
    expect(entries, hasLength(1));
    expect(entries.single.items.map((i) => i.text).toList(),
        ['survey', 'implement', 'verify']);
    expect(entries.single.approval, PlanApproval.none);
    expect(plugin.store.state.items, hasLength(3));
    expect(plugin.store.state.inProgress, ['implement']);
  });

  test('the plan survives a store round trip: a resumed host derives it',
      () async {
    final ws = await Directory.systemTemp.createTemp('tina_plans_ws_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final storePath = '${ws.path}/session.db';

    final startedPlugin = PlansPlugin();
    final started = Host.start(HostConfig(
      providerFactory: (_) => ScriptedProvider([]),
      workingDirectory: ws.path,
      storePath: storePath,
      plugins: [startedPlugin],
    ));
    await started.session.loop.runTurn(const Input('plan it', id: 't1'));
    await _call(started.session.loop, startedPlugin, {
      'items': [
        {'text': 'only step', 'state': 'in_progress'},
      ],
      'approval': 'requested',
    });
    final sessionId = started.session.id;
    started.close();

    final resumed = Host.resume(
      HostConfig(
        providerFactory: (_) => ScriptedProvider([]),
        workingDirectory: ws.path,
        storePath: storePath,
        plugins: [PlansPlugin()],
      ),
      sessionId,
    );
    // The derive carries the plan exactly as the running session left it
    // — the entry is the truth, replayed from the same log the messages
    // come from.
    final view = resumed.session.loop.derive();
    expect(view.plan, isNotNull);
    expect(view.plan!.items.single.text, 'only step');
    expect(view.plan!.approval, PlanApproval.requested);
    resumed.close();
  });

  test('the schema and the validation hold the line: bad calls are tool '
      'errors, the log is untouched', () async {
    final (loop, plugin, _) = _wired();
    await loop.runTurn(const Input('go', id: 't1'));

    final before = loop.log.length;
    expect(
        (await _call(loop, plugin, {
          'items': [
            {'text': 'x', 'state': 'sideways'},
          ],
        }))
            .isError,
        isTrue);
    expect(
        (await _call(loop, plugin, {
          'items': [
            {
              'text': 'x',
              'state': 'pending',
              'children': [
                {
                  'text': 'y',
                  'state': 'pending',
                  'children': [
                    {'text': 'z', 'state': 'pending'},
                  ],
                },
              ],
            },
          ],
        }))
            .isError,
        isTrue);
    expect(
        (await _call(loop, plugin, {
          'items': [
            {'text': 'a', 'state': 'in_progress'},
            {'text': 'b', 'state': 'in_progress'},
          ],
        }))
            .isError,
        isTrue);
    expect(
        (await _call(loop, plugin, {
          'approval': 'requested',
        }))
            .isError,
        isTrue,
        reason: 'approval-only with no plan is an error');
    expect(loop.log.length, before,
        reason: 'a rejected call appends nothing');
    expect(plugin.store.state.isEmpty, isTrue);
  });

  test('an edited plan clears approval; a progress tick preserves it',
      () async {
    final (loop, plugin, _) = _wired();
    await loop.runTurn(const Input('go', id: 't1'));

    await _call(loop, plugin, {
      'items': [
        {'text': 'step', 'state': 'pending'},
      ],
    });
    // Request approval on the unchanged plan.
    final asked = await _call(loop, plugin, {'approval': 'requested'});
    expect(asked.content, contains('waiting for user approval'));
    expect(plugin.store.state.approval, PlanApproval.requested);

    // A progress tick: same content, new state — approval preserved.
    await _call(loop, plugin, {
      'items': [
        {'text': 'step', 'state': 'done'},
      ],
    });
    expect(plugin.store.state.approval, PlanApproval.requested);

    // An edit: new content — approval cleared.
    await _call(loop, plugin, {
      'items': [
        {'text': 'step two', 'state': 'pending'},
      ],
    });
    expect(plugin.store.state.approval, PlanApproval.none);
  });

  test('the prompt section renders state, subtasks and the approval '
      'posture; an empty plan adds nothing', () async {
    final (loop, plugin, _) = _wired();
    await loop.runTurn(const Input('go', id: 't1'));
    expect(_sections(loop, plugin), isEmpty,
        reason: 'no plan, no section — an empty plan is noise');

    await _call(loop, plugin, {
      'items': [
        {
          'text': 'parent',
          'state': 'in_progress',
          'children': [
            {'text': 'child', 'state': 'pending'},
          ],
        },
        {'text': 'done one', 'state': 'done'},
      ],
      'approval': 'requested',
    });
    final section = _sections(loop, plugin).single;
    expect(section, startsWith('<current-plan>'));
    expect(section, contains('update_plan'));
    expect(section, contains('[~] parent'));
    expect(section, contains('  [ ] child'));
    expect(section, contains('[x] done one'));
    expect(section,
        contains('wait for their approval before doing the planned work'));
    expect(section, endsWith('</current-plan>\n'));

    // And the user answers through the command; the section follows.
    final services = Services()
      ..put<Terminal>(_CaptureTerminal())
      ..put<Commands>(Commands());
    final own = PlansPlugin(services: services);
    final loop2 = AgentLoop(
        provider: ScriptedProvider([]), plugins: [own]);
    own.mountOn(loop2);
    await loop2.runTurn(const Input('go', id: 't1'));
    await _call(loop2, own, {
      'items': [
        {'text': 'step', 'state': 'pending'},
      ],
    });
    own.register();
    services.get<Commands>()['plan']!.handler('approve');
    expect(_sections(loop2, own).single, contains('proceed'));
  });

  test('the /plan command: show, add, toggle, approve, clear — told '
      'through the terminal', () async {
    final terminal = _CaptureTerminal();
    final services = Services()
      ..put<Terminal>(terminal)
      ..put<Commands>(Commands());
    final (loop, plugin, _) = _wired(services: services);
    plugin.register();
    await loop.runTurn(const Input('go', id: 't1'));
    final handler = services.get<Commands>()['plan']!.handler;

    handler('add first step');
    expect(terminal.lines.last, contains('1. [ ] first step'));
    expect(
        services.get<Commands>()['plan']!.description,
        contains('approve'));

    handler('');
    expect(terminal.lines.last, contains('Plan:'));

    handler('done 1');
    expect(terminal.lines.last, contains('1. [x] first step'));

    handler('pending 1');
    expect(terminal.lines.last, contains('1. [ ] first step'));

    handler('request-approval');
    expect(terminal.lines.where((l) => l.contains('REQUESTED')), isNotEmpty);

    handler('approve');
    expect(terminal.lines.where((l) => l.contains('approved')), isNotEmpty);

    handler('clear');
    expect(terminal.lines.last, 'Plan cleared.');
    expect(plugin.store.state.isEmpty, isTrue);

    handler('done 1');
    expect(terminal.lines.last, 'No plan item 1.');
  });

  test('a requested plan rides the wired Approver: yes approves, no '
      'rejects, the tool result names the outcome', () async {
    final (loop, plugin, _) = _wired(approver: (request, reason) async {
      expect(reason, contains('approve this plan?'));
      return Approval.yes;
    });
    await loop.runTurn(const Input('go', id: 't1'));
    final result = await _call(loop, plugin, {
      'items': [
        {'text': 'the work', 'state': 'pending'},
      ],
      'approval': 'requested',
    });
    expect(result.content, contains('approved by the user'));
    expect(plugin.store.state.approval, PlanApproval.approved);
    final entry = loop.log.whereType<PlanChangedEntry>().last;
    expect(entry.approval, PlanApproval.approved);

    final (loop2, plugin2, _) = _wired(approver: (request, reason) async {
      return Approval.no;
    });
    await loop2.runTurn(const Input('go', id: 't1'));
    final refused = await _call(loop2, plugin2, {
      'items': [
        {'text': 'the work', 'state': 'pending'},
      ],
      'approval': 'requested',
    });
    expect(refused.content, contains('rejected it'));
    expect(plugin2.store.state.approval, PlanApproval.rejected);
    expect(plugin2.store.state.items.single.text, 'the work',
        reason: 'a rejection does not clear the plan');
  });

  test('nothing wired is the old park: the plan stays requested and the '
      'command answers later', () async {
    final (loop, plugin, _) = _wired();
    await loop.runTurn(const Input('go', id: 't1'));
    final result = await _call(loop, plugin, {
      'items': [
        {'text': 'the work', 'state': 'pending'},
      ],
      'approval': 'requested',
    });
    expect(result.content, contains('waiting for user approval'));
    expect(plugin.store.state.approval, PlanApproval.requested);

    plugin.register();
    // No terminal wired? register() is a no-op without services — the
    // command path needs the locator. Wire one and answer.
    final services = Services()
      ..put<Terminal>(_CaptureTerminal())
      ..put<Commands>(Commands());
    final (loop2, plugin2, _) = _wired(services: services);
    plugin2.register();
    await loop2.runTurn(const Input('go', id: 't2'));
    await _call(loop2, plugin2, {
      'items': [
        {'text': 'the work', 'state': 'pending'},
      ],
      'approval': 'requested',
    });
    services.get<Commands>()['plan']!.handler('reject');
    expect(plugin2.store.state.approval, PlanApproval.rejected);
    expect(_sections(loop2, plugin2).single,
        contains('The user rejected this plan'));
  });

  test('the entry round trips the store bytes: toJson then fromJson is '
      'the same plan', () {
    const entry = PlanChangedEntry(
      items: [
        PlanEntryItem('parent', state: 'in_progress', children: [
          PlanEntryItem('child', state: 'done'),
        ]),
        PlanEntryItem('second', state: 'pending'),
      ],
      approval: PlanApproval.approved,
    );
    final back = SessionEntry.fromJson(entry.toJson()..remove('seq'));
    expect(back, isA<PlanChangedEntry>());
    final plan = back as PlanChangedEntry;
    expect(plan.items.first.children.single.text, 'child');
    expect(plan.items.last.text, 'second');
    expect(plan.approval, PlanApproval.approved);

    // Junk is refused, not silently repaired.
    expect(() => SessionEntry.fromJson({
          'type': 'plan_changed',
          'items': [
            {'text': 'x', 'state': 'sideways'},
          ],
        }), throwsA(isA<FormatException>()));
    expect(() => SessionEntry.fromJson({
          'type': 'plan_changed',
          'items': [
            {
              'text': 'x',
              'state': 'pending',
              'children': [
                {
                  'text': 'y',
                  'state': 'pending',
                  'children': [
                    {'text': 'z', 'state': 'pending'},
                  ],
                },
              ],
            },
          ],
        }), throwsA(isA<FormatException>()));
  });
}

Future<ToolResult> _call(AgentLoop loop, PlansPlugin plugin,
    Map<String, Object?> input) async {
  return plugin.execute(input);
}

List<String> _sections(AgentLoop loop, PlansPlugin plugin) {
  // Rebuild the prompt-phase view: the sections the plugins add for the
  // current state.
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

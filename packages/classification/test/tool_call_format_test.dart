import 'dart:async';

import 'package:classification/judgments.dart';
import 'package:classification/plugin.dart';
import 'package:classification/tool_call_format.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class _Output implements Terminal {
  final lines = <String?>[];
  @override
  void writeln([String? line]) => lines.add(line);
  @override
  Future<String> ask(String prompt) async => throw UnimplementedError();
}

JudgmentResult _answer(JudgmentRequest request, String choice) =>
    JudgmentResult.fromJson({
      'model': 'typesafe-fixture',
      'usage': {},
      'answers': {
        'tool_call_format': {
          'type': 'choice',
          'choice': choice,
          'confidence': .99,
          'probabilities': {
            'GOOD': choice == 'GOOD' ? 1 : 0,
            'BAD': choice == 'BAD' ? 1 : 0,
          },
        },
      },
    }, request: request);

class _Judgments implements JudgmentService {
  _Judgments(this.decide);
  final FutureOr<JudgmentResult> Function(JudgmentRequest) decide;
  final requests = <JudgmentRequest>[];
  final tokens = <JudgmentCancellation?>[];
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    requests.add(request);
    tokens.add(cancellation);
    return await decide(request);
  }
}

class _Tools extends AgentPlugin {
  @override
  String get id => 'test/tools';
  @override
  List<ToolSchema> get tools => [
    for (final name in [
      'bash',
      'exec',
      'read',
      'write',
      'edit',
      'ls',
      'stat',
      'glob',
    ])
      ToolSchema(name: name, description: '', inputSchema: {}),
  ];
}

class _Permissions extends AgentPlugin {
  _Permissions({this.deny = false});
  final bool deny;
  final calls = <ToolUse>[];
  @override
  String get id => 'test/permissions';
  @override
  int get order => 1100;
  @override
  void beforeToolCall(TurnContext context) {
    calls.add(context.call!);
    if (deny) context.decision = const Decision.deny('Permission denied');
  }
}

TurnContext _context({
  String tool = 'exec',
  String inputId = 'one',
  Map<String, Object?> input = const {
    'program': 'gh',
    'args': ['pr', 'view', '429'],
  },
  CancelToken? token,
}) => TurnContext(
  token ?? CancelToken(),
  input: Input('inspect PR', id: inputId),
  messages: [],
  promptSections: [],
  pinnedTools: [],
  call: ToolUse(id: 'call', name: tool, input: input),
);

void main() {
  test(
    'file path rewrites precede permission review and preserve edit contents',
    () async {
      const correct = '/Volumes/T7/projects/zombie_golf/lib/main.dart';
      const typo = '/VVolumes/T7/projects/zombie_golf/lib/main.dart';
      final service = _Judgments((request) {
        final input = (request.state.value as Map)['input'] as Map;
        return _answer(request, input['filePath'] == typo ? 'BAD' : 'GOOD');
      });
      final output = _Output();
      final plugin = ClassificationPlugin(
        terminal: output,
        open: () => null,
        toolCalls: ToolCallFormatReviewer(
          terminal: output,
          readWorkspace: () => '/Volumes/T7/projects/zombie_golf',
          open: () => ClassificationLease(
            service: service,
            budget: JudgmentRequestBudget(),
            close: () {},
          ),
        ),
      );
      addTearDown(plugin.closeSession);
      final permissions = _Permissions();
      final provider = ScriptedProvider([
        scriptedReply(
          '',
          calls: [
            ToolUseBlock(
              id: 'read',
              name: 'read',
              input: {'filePath': correct},
            ),
          ],
        ),
        scriptedReply(
          '',
          calls: [
            ToolUseBlock(
              id: 'typo',
              name: 'edit',
              input: {
                'filePath': typo,
                'oldString': 'private old contents',
                'newString': 'private new contents',
              },
            ),
          ],
        ),
        scriptedReply(
          '',
          calls: [
            ToolUseBlock(
              id: 'fixed',
              name: 'edit',
              input: {
                'filePath': correct,
                'oldString': 'private old contents',
                'newString': 'private new contents',
              },
            ),
          ],
        ),
        scriptedReply('done'),
      ]);
      final loop = AgentLoop(
        provider: provider,
        plugins: [_Tools(), plugin, permissions],
      );
      final edits = <Map<String, Object?>>[];
      loop.registerExecutor(
        'read',
        (_) async => const ToolResult('private file body'),
      );
      loop.registerExecutor('edit', (input) async {
        edits.add(input);
        return const ToolResult('edited');
      });
      await loop.runTurn(const Input('rename the inner method', id: 'one'));
      expect(permissions.calls.map((call) => call.id), ['read', 'fixed']);
      expect(edits.single['filePath'], correct);
      expect(edits.single['newString'], 'private new contents');
      final feedback = provider.requests[2].messages
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .where((r) => r.toolUseId == 'typo')
          .single;
      expect(feedback.isError, true);
      expect(feedback.content, contains('File path needs review'));
      final state = service.requests[1].state.value as Map;
      expect(state['recent_successful_paths'], [correct]);
      expect(state['path_context'], {
        'resolved_lexically': typo,
        'within_workspace_lexically': false,
        'existence': 'not_checked',
      });
      expect(state['input'], {'filePath': typo});
      expect(state.toString(), isNot(contains('private')));
      expect(
        service.requests[1].questions['tool_call_format']!.toJson().toString(),
        contains('/projects/projects/project'),
      );
      expect(
        plugin.trace.exchanges.map((e) => e.title),
        everyElement('File path check'),
      );
      expect(loop.hookFailures, isEmpty);
    },
  );

  test(
    'file path GOOD still needs permission and never rewrites the target',
    () async {
      final output = _Output();
      final service = _Judgments((request) => _answer(request, 'GOOD'));
      final reviewer = ToolCallFormatReviewer(
        terminal: output,
        readWorkspace: () => '/workspace/project',
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      );
      final context = _context(
        tool: 'write',
        input: {
          'filePath': '/deliberate/outside/new.dart',
          'content': 'private body',
        },
      );
      await reviewer.review(context);
      expect(context.call!.input['filePath'], '/deliberate/outside/new.dart');
      final permission = _Permissions(deny: true);
      permission.beforeToolCall(context);
      expect(context.decision.kind, DecisionKind.deny);
      expect(
        service.requests.single.state.value.toString(),
        isNot(contains('private body')),
      );
      expect(
        service.requests.single.questions['tool_call_format']!
            .toJson()
            .toString(),
        contains('not by itself BAD'),
      );
    },
  );

  test(
    'path evidence is lexical, bounded, success-only and scoped to workspace',
    () async {
      var workspace = '/workspace/project';
      final service = _Judgments((request) => _answer(request, 'GOOD'));
      final reviewer = ToolCallFormatReviewer(
        terminal: _Output(),
        readWorkspace: () => workspace,
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      );
      for (var i = 0; i < 10; i++) {
        reviewer.observeResult(
          _context(tool: 'read', input: {'filePath': 'lib/file$i.dart'})
            ..toolResult = const ToolResult('private body'),
        );
      }
      reviewer.observeResult(
        _context(tool: 'edit', input: {'filePath': 'failed.dart'})
          ..toolResult = ToolResult.error('File not found'),
      );
      final context = _context(
        tool: 'edit',
        input: {'filePath': 'lib/../main.dart'},
      );
      await reviewer.review(context);
      final state = service.requests.last.state.value as Map;
      expect(state['recent_successful_paths'], [
        for (var i = 2; i < 10; i++) '/workspace/project/lib/file$i.dart',
      ]);
      expect(
        (state['path_context'] as Map)['resolved_lexically'],
        '/workspace/project/main.dart',
      );
      expect((state['path_context'] as Map)['existence'], 'not_checked');
      workspace = '/workspace/other';
      await reviewer.review(_context(tool: 'ls', input: {}));
      final next = service.requests.last.state.value as Map;
      expect(next['recent_successful_paths'], isEmpty);
      expect((next['path_context'] as Map)['resolved_lexically'], workspace);
    },
  );

  test(
    'malformed file paths request a rewrite without opening a classifier',
    () async {
      var opens = 0;
      final reviewer = ToolCallFormatReviewer(
        terminal: _Output(),
        open: () {
          opens++;
          return null;
        },
      );
      final trace = ClassificationTrace();
      addTearDown(trace.close);
      for (final value in ['', 42, 'bad\u0000path']) {
        final context = _context(
          tool: 'edit',
          inputId: '$value',
          input: {'filePath': value},
        );
        await reviewer.review(context, trace: trace);
        expect(context.decision.kind, DecisionKind.deny);
        expect(context.decision.reason, contains('non-empty path without NUL'));
      }
      expect(opens, 0);
      expect(trace.exchanges.map((e) => e.outcome?.label), [
        'Rewrite',
        'Rewrite',
        'Rewrite',
      ]);
    },
  );

  for (final scenario in [
    ('print test', 'BAD', DecisionKind.deny),
    ('test whether bash works', 'GOOD', DecisionKind.allow),
  ]) {
    test('shell wrapper review uses task evidence: ${scenario.$1}', () async {
      final service = _Judgments((request) {
        expect((request.state.value as Map)['current_task'], scenario.$1);
        return _answer(request, scenario.$2);
      });
      final reviewer = ToolCallFormatReviewer(
        terminal: _Output(),
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      );
      final context = _context(
        tool: 'bash',
        input: {'command': "bash -c 'echo test'"},
      )..input = Input(scenario.$1, id: 'one');
      await reviewer.review(context);
      expect(context.decision.kind, scenario.$3);
      expect(
        (service.requests.single.state.value as Map)['current_task'],
        scenario.$1,
      );
      expect(toolCallFormatPolicy, contains("bash -c 'echo test' is BAD"));
      expect(
        toolCallFormatPolicy,
        contains('An explicit task to test Bash itself'),
      );
      final trace = ClassificationTrace();
      final retried = _context(
        tool: 'bash',
        input: {'command': "bash -c 'echo test'"},
      )..input = Input(scenario.$1, id: 'one');
      await reviewer.review(retried, trace: trace);
      expect(trace.exchanges.single.title, 'Command formatting');
      expect(trace.exchanges.single.outcome?.label, scenario.$2);
      reviewer.close();
      trace.close();
    });
  }

  test(
    'BAD never reaches approval/execution; model rewrite gets fresh checks',
    () async {
      final service = _Judgments((request) {
        final input = (request.state.value as Map)['input'] as Map;
        return _answer(request, input.containsKey('command') ? 'BAD' : 'GOOD');
      });
      final output = _Output();
      var closed = 0;
      final reviewer = ToolCallFormatReviewer(
        terminal: output,
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () => closed++,
        ),
      );
      final plugin = ClassificationPlugin(
        terminal: output,
        open: () => null,
        toolCalls: reviewer,
      );
      addTearDown(plugin.closeSession);
      final permissions = _Permissions();
      final rewritten = {
        'program': 'gh',
        'args': ['pr', 'view', '429'],
        'working_directory': '/workspace/project',
        'network': true,
        'network_reason': 'Inspect the requested PR',
      };
      final provider = ScriptedProvider([
        scriptedReply(
          '',
          calls: [
            ToolUseBlock(
              id: 'wrapped',
              name: 'bash',
              input: {
                'command':
                    r'TASK_DIR=/workspace/project; cd "$TASK_DIR"; gh pr view 429',
                'network': true,
              },
            ),
          ],
        ),
        scriptedReply(
          '',
          calls: [ToolUseBlock(id: 'clean', name: 'exec', input: rewritten)],
        ),
        scriptedReply('done'),
      ]);
      final loop = AgentLoop(
        provider: provider,
        plugins: [_Tools(), plugin, permissions],
      );
      final executed = <Map<String, Object?>>[];
      for (final tool in ['exec', 'bash']) {
        loop.registerExecutor(tool, (input) async {
          executed.add(input);
          return const ToolResult('PR 429');
        });
      }
      final outcome = await loop.runTurn(const Input('inspect PR', id: 'one'));
      expect(executed, [rewritten]);
      expect(permissions.calls.map((c) => c.id), ['clean']);
      expect(permissions.calls.single.input, rewritten);
      final feedback = provider.requests[1].messages
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .single;
      expect(feedback.toolUseId, 'wrapped');
      expect(feedback.isError, true);
      expect(feedback.content, contains('Rewrite the tool call now'));
      expect(feedback.content, contains('not executed'));
      expect(outcome.stopReason, StopReason.complete);
      expect(service.requests, hasLength(2));
      expect(closed, 2);
      final exchanges = plugin.trace.exchanges;
      expect(exchanges.map((e) => e.outcome?.label), ['BAD', 'GOOD']);
      expect(loop.hookFailures, isEmpty);
    },
  );

  test('GOOD does not override a subsequent permission denial', () async {
    final output = _Output();
    final service = _Judgments((r) => _answer(r, 'GOOD'));
    final plugin = ClassificationPlugin(
      terminal: output,
      open: () => null,
      toolCalls: ToolCallFormatReviewer(
        terminal: output,
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      ),
    );
    addTearDown(plugin.closeSession);
    final permissions = _Permissions(deny: true);
    final loop = AgentLoop(
      provider: ScriptedProvider([
        scriptedReply(
          '',
          calls: [
            ToolUseBlock(id: 'one', name: 'exec', input: {'program': 'gh'}),
          ],
        ),
        scriptedReply('permission refused'),
      ]),
      plugins: [_Tools(), plugin, permissions],
    );
    var executed = false;
    loop.registerExecutor('exec', (_) async {
      executed = true;
      return const ToolResult('unexpected');
    });
    final outcome = await loop.runTurn(const Input('go', id: 'one'));
    expect(executed, false);
    expect(permissions.calls, hasLength(1));
    expect(
      outcome.messages
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .single
          .content,
      contains('Permission denied'),
    );
  });

  test(
    'repeated BAD calls stop after two rewrites; a new input resets the limit',
    () async {
      final output = _Output();
      final service = _Judgments((r) => _answer(r, 'BAD'));
      final plugin = ClassificationPlugin(
        terminal: output,
        open: () => null,
        toolCalls: ToolCallFormatReviewer(
          terminal: output,
          open: () => ClassificationLease(
            service: service,
            budget: JudgmentRequestBudget(),
            close: () {},
          ),
        ),
      );
      addTearDown(plugin.closeSession);
      final provider = ScriptedProvider([
        for (var i = 0; i < 3; i++)
          scriptedReply(
            '',
            calls: [
              ToolUseBlock(id: '$i', name: 'exec', input: {'program': 'gh'}),
            ],
          ),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [_Tools(), plugin]);
      var executed = 0;
      loop.registerExecutor('exec', (_) async {
        executed++;
        return const ToolResult('unexpected');
      });
      final outcome = await loop.runTurn(const Input('go', id: 'one'));
      expect(executed, 0);
      expect(provider.requests, hasLength(3));
      expect(outcome.stopRequest?.code, 'tool_format_rewrite_limit');
      expect(outcome.stopRequest?.pluginId, 'tina/classification');
      final next = _context(inputId: 'two');
      await plugin.beforeToolCall(next);
      expect(next.cancelled, false);
      expect(next.decision.kind, DecisionKind.deny);
    },
  );

  test(
    'full clean pipeline is judged without history, output or environment',
    () async {
      final service = _Judgments((r) => _answer(r, 'GOOD'));
      final reviewer = ToolCallFormatReviewer(
        terminal: _Output(),
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      );
      const command = 'otool -tvV library.a | grep -A 30 symbol | head -n 35';
      final context = _context(
        tool: 'bash',
        input: {
          'command': command,
          'working_directory': '/workspace/project',
          'network_reason': 'not part of format analysis',
        },
      );
      context.messages.add(
        Message(
          role: Role.user,
          content: [TextBlock('private unrelated history')],
        ),
      );
      await reviewer.review(context);
      expect(context.decision.kind, DecisionKind.allow);
      expect(service.requests.single.state.value, {
        'tool': 'bash',
        'current_task': 'inspect PR',
        'input': {
          'command': command,
          'working_directory': '/workspace/project',
        },
      });
      expect(
        context.call!.input['network_reason'],
        'not part of format analysis',
      );
      expect(context.messages, hasLength(1));
    },
  );

  for (final action in ['cancel', 'close', 'timeout']) {
    test(
      '$action cancels pending classification and closes its lease',
      () async {
        final pending = Completer<JudgmentResult>();
        final entered = Completer<void>();
        final service = _Judgments((_) {
          entered.complete();
          return pending.future;
        });
        final token = CancelToken();
        var closed = 0;
        final output = _Output();
        final reviewer = ToolCallFormatReviewer(
          terminal: output,
          readTimeout: () => action == 'timeout'
              ? const Duration(milliseconds: 10)
              : const Duration(seconds: 10),
          open: () => ClassificationLease(
            service: service,
            budget: JudgmentRequestBudget(),
            close: () => closed++,
          ),
        );
        final context = _context(token: token);
        final reviewed = reviewer.review(context);
        await entered.future;
        if (action == 'cancel') token.cancel('escape');
        if (action == 'close') reviewer.close();
        await reviewed.timeout(const Duration(seconds: 1));
        expect(service.tokens.single!.isCancelled, true);
        expect(closed, 1);
        expect(output.lines, action == 'timeout' ? hasLength(1) : isEmpty);
        pending.complete(_answer(service.requests.single, 'BAD'));
        await Future<void>.delayed(Duration.zero);
        expect(
          context.decision.kind,
          DecisionKind.allow,
          reason: 'a late BAD result must not request a rewrite',
        );
        reviewer.close();
        expect(closed, 1);
      },
    );
  }

  test(
    'disabled, unsupported or already-denied calls never open a service',
    () async {
      var opens = 0;
      var enabled = true;
      final reviewer = ToolCallFormatReviewer(
        terminal: _Output(),
        enabled: () => enabled,
        open: () {
          opens++;
          return null;
        },
      );
      await reviewer.review(_context(tool: 'update_plan'));
      final denied = _context()
        ..decision = const Decision.deny('earlier guard');
      await reviewer.review(denied);
      enabled = false;
      await reviewer.review(_context());
      expect(opens, 0);
      expect(denied.decision.reason, 'earlier guard');
    },
  );

  test(
    'missing config and service failures keep normal permission checks',
    () async {
      for (final mode in ['missing', 'open', 'transport', 'invalid']) {
        final output = _Output();
        var closed = 0;
        final reviewer = ToolCallFormatReviewer(
          terminal: output,
          open: () {
            if (mode == 'missing') return null;
            if (mode == 'open') throw StateError('private credential');
            return ClassificationLease(
              service: _Judgments((_) {
                if (mode == 'transport')
                  throw const JudgmentException(JudgmentFailure.transport);
                throw FormatException('private response');
              }),
              budget: JudgmentRequestBudget(),
              close: () => closed++,
            );
          },
        );
        final context = _context();
        await reviewer.review(context);
        await reviewer.review(_context());
        expect(context.decision.kind, DecisionKind.allow);
        expect(context.cancelled, false);
        expect(
          output.lines,
          hasLength(1),
          reason: 'do not repeat the same notice',
        );
        expect(output.lines.single, contains('normal permission checks'));
        expect(output.lines.single, isNot(contains('private')));
        expect(closed, ['missing', 'open'].contains(mode) ? 0 : 2);
      }
    },
  );

  test(
    'oversized commands are not truncated or sent to the classifier',
    () async {
      final service = _Judgments((r) => _answer(r, 'BAD'));
      final output = _Output();
      var closed = false;
      final reviewer = ToolCallFormatReviewer(
        terminal: output,
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () => closed = true,
        ),
      );
      final context = _context(tool: 'bash', input: {'command': 'x' * 30000});
      await reviewer.review(context);
      expect(context.decision.kind, DecisionKind.allow);
      expect(service.requests, isEmpty);
      expect(closed, true);
      expect(output.lines.single, contains('requestTooLarge'));
    },
  );
}

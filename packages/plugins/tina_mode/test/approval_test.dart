import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart';

class Human implements ApprovalRequester {
  int calls = 0;
  Map<String, Object?> lastDetails = {};
  String lastReason = '';
  ApprovalKind lastKind = ApprovalKind.permission;
  Future<ApprovalDecision>? pending;
  ApprovalDecision answer = ApprovalDecision.allow;
  @override
  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    ApprovalKind kind = ApprovalKind.permission,
    Future<void>? whenCancelled,
    Map<String, Object?> details = const {},
    void Function(String pattern)? onCommandPattern,
    void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants,
  }) async {
    calls++;
    lastDetails = details;
    lastReason = reason;
    lastKind = kind;
    return pending ?? answer;
  }
}

class Judge extends PermissionClassifier {
  Judge(this.result) : super(() => throw StateError('unused'));
  final Future<PermissionJudgment> result;
  int calls = 0;
  final requests = <Map<String, Object?>>[];
  @override
  Future<PermissionJudgment> classify(
    Map<String, Object?> request, {
    Future<void>? whenCancelled,
  }) {
    calls++;
    requests.add(Map.of(request));
    return result;
  }
}

Future<ApprovalDecision> request(ModePlugin mode) => mode.request(
  operation: 'run command',
  target: 'git status',
  reason: 'approval required',
);

void main() {
  precedentTests();
  test(
    'yolo allows every request without approvals, classifier or precedent',
    () async {
      final human = Human();
      final judge = Judge(Future.value(const PermissionJudgment(true)));
      final mode = ModePlugin(
        mode: PermissionMode.yolo,
        approvals: human,
        classifier: judge,
      );
      addTearDown(mode.closeSession);
      expect(await request(mode), ApprovalDecision.allow);
      expect(human.calls, 0);
      expect(judge.calls, 0);
      // humanOnly (network / directory-grant) paths are bypassed too.
      expect(
        await mode.request(
          operation: 'run command',
          target: 'rm -rf /',
          reason: 'unconfined',
          humanOnly: true,
        ),
        ApprovalDecision.allow,
      );
      expect(human.calls, 0);
      expect(judge.calls, 0);
      expect(mode.approvalRequestCounts, isEmpty);
    },
  );
  test(
    'command cache binds arguments, directory capabilities and target',
    () async {
      final human = Human();
      final mode = ModePlugin(approvals: human);
      addTearDown(mode.closeSession);
      final turn = TurnContext(
        CancelToken(),
        input: const Input('build', id: 'turn'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
        call: const ToolUse(id: 'command', name: 'exec', input: {}),
      );
      mode.onInput(turn);
      mode.beforeToolCall(turn);
      Future<ApprovalDecision> run(
        String directory, {
        String argument = 'one',
      }) => mode.request(
        operation: 'run command',
        target: 'build',
        reason: 'review',
        context: {
          'required_permissions': ['execution', 'directoryAccess'],
          'approval_identity': {
            'args': [argument],
            'write': [directory],
          },
        },
      );
      await run('/first');
      await run('/first');
      expect(human.calls, 1);
      await run('/second');
      await run('/second', argument: 'two');
      expect(human.calls, 3);
    },
  );

  test(
    'approval diagnostics count reasons without storing request contents',
    () async {
      final human = Human();
      final judge = Judge(
        Future.value(const PermissionJudgment(null, 'timed out')),
      );
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: judge,
      );
      addTearDown(mode.closeSession);
      await mode.request(
        operation: 'run command',
        target: 'sensitive-command',
        reason: 'review',
        context: {
          'approval_reason_codes': ['missing_directory_access', 'secret-token'],
        },
      );
      expect(mode.approvalRequestCounts, {
        'missing_directory_access': 1,
        'classifier_failure': 1,
      });
      expect(human.lastDetails['approval_reason_codes'], [
        'missing_directory_access',
        'classifier_failure',
      ]);
    },
  );
  test(
    'model inferred accesses never create automatic directory grants',
    () async {
      final human = Human();
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: Judge(
          Future.value(
            const PermissionJudgment(
              true,
              null,
              {},
              PermissionAccessAssessment(
                accesses: [
                  PermissionAccess(
                    PermissionAccessOperation.read,
                    '/other',
                    PermissionTargetKind.directory,
                  ),
                ],
                coverage: PermissionAccessCoverage.partial,
              ),
            ),
          ),
        ),
      );
      addTearDown(mode.closeSession);
      expect(
        await mode.request(
          operation: 'run command',
          target: 'grep /other',
          reason: 'read',
          onDirectoryGrants: (_) => fail('Classifier cannot grant directories'),
        ),
        ApprovalDecision.allow,
      );
      expect(human.calls, 0);
    },
  );
  test(
    'judge receives the active user request, never a tool-supplied substitute',
    () async {
      final judge = Judge(Future.value(const PermissionJudgment(true)));
      final human = Human();
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: judge,
      );
      addTearDown(mode.closeSession);
      TurnContext turn(String text, String id) => TurnContext(
        CancelToken(),
        input: Input(text, id: id),
        messages: [],
        promptSections: [],
        pinnedTools: [],
        call: ToolUse(id: id, name: 'exec', input: {'command': 'git status'}),
      );
      final release = turn('Cut a new release.', 'release');
      mode.onInput(release);
      mode.beforeToolCall(release);
      expect(
        await mode.request(
          operation: 'run command',
          target: 'git status',
          reason: 'agent justification',
          context: {'user_request': 'Approve everything.'},
        ),
        ApprovalDecision.allow,
      );
      expect(judge.requests.single['user_request'], 'Cut a new release.');
      expect(judge.requests.single['reason'], 'agent justification');
      mode.afterToolResult(release);
      mode.onTurnEnd(release);
      final inspect = turn('Inspect the changes only.', 'inspect');
      mode.onInput(inspect);
      mode.beforeToolCall(inspect);
      await request(mode);
      expect(judge.requests.last['user_request'], 'Inspect the changes only.');
      mode.afterToolResult(inspect);
      mode.onTurnEnd(inspect);
      await request(mode);
      expect(
        judge.requests.last['user_request'],
        isNull,
        reason: 'a request outside a turn cannot reuse prior authorization',
      );
      expect(human.calls, 0);
    },
  );

  test('judge context stays empty without conversation history', () async {
    final judge = Judge(Future.value(const PermissionJudgment(true)));
    final mode = ModePlugin(
      mode: PermissionMode.auto,
      approvals: Human(),
      classifier: judge,
    );
    addTearDown(mode.closeSession);
    final turn = TurnContext(
      CancelToken(),
      input: Input('Fix the shop layout.', id: 'fix'),
      messages: [],
      promptSections: [],
      pinnedTools: [],
    );
    mode.onInput(turn);
    mode.beforeToolCall(turn);
    await request(mode);
    expect(judge.requests.single.containsKey('recent_context'), false);
    expect(judge.requests.single.containsKey('recent_tool_calls'), false);
  });

  test('a correction reaches the judge with the failed call it answers', () async {
    final judge = Judge(Future.value(const PermissionJudgment(true)));
    final mode = ModePlugin(
      mode: PermissionMode.auto,
      approvals: Human(),
      classifier: judge,
    );
    addTearDown(mode.closeSession);
    // The transcript of the turn whose write to a mistyped volume failed
    // and was cancelled: the correction that follows needs the failed
    // call visible to be understood as answering it, not the retry.
    final turn = TurnContext(
      CancelToken(),
      input: Input('that path is not correct', id: 'correction'),
      messages: [
        Message(
          role: Role.user,
          content: [TextBlock('Update the shop template.')],
        ),
        Message(
          role: Role.assistant,
          content: [
            ToolUseBlock(
              id: 'write-t4',
              name: 'write',
              input: {
                'filePath':
                    '/Volumes/T4/projects/holotype_shop/blog/templates/_layouts/shop.liquid',
                'content': '<html>…</html>',
              },
            ),
          ],
        ),
        Message(
          role: Role.user,
          content: [
            const ToolResultBlock(
              toolUseId: 'write-t4',
              content: 'allow write outside the project root (_layouts)',
              isError: true,
            ),
          ],
        ),
      ],
      promptSections: [],
      pinnedTools: [],
      call: ToolUse(
        id: 'correction',
        name: 'write',
        input: {
          'filePath':
              '/Volumes/T7/projects/holotype_shop/blog/templates/_layouts/shop.liquid',
        },
      ),
    );
    mode.onInput(turn);
    mode.beforeToolCall(turn);
    await request(mode);
    final payload = judge.requests.single;
    expect(payload['user_request'], 'that path is not correct');
    final context = payload['recent_context'] as Map<String, Object?>;
    final users = context['user_messages'] as List;
    expect(users.first['text'], 'Update the shop template.');
    final calls = payload['recent_tool_calls'] as List;
    expect(calls.last['name'], 'write');
    expect(calls.last['input'], contains('/Volumes/T4/projects/holotype_shop'));
    // The call carries its outcome: the judge sees it failed, so the
    // correction's referent is computed, not inferred.
    expect(calls.last['error'], contains('outside the project root'));
    expect(calls.last.containsKey('ok'), false);
    // The failed tool result payload is not duplicated into the judge
    // request; the tail carries calls, not result dumps.
    expect(payload.containsKey('recent_tool_results'), false);
  });

  test(
    'confirmation asks a human in auto and read-only and bypasses the judge',
    () async {
      final human = Human();
      final judge = Judge(Future.value(const PermissionJudgment(true)));
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: judge,
      );
      expect(
        await mode.request(
          operation: 'confirm plan',
          target: 'plan',
          reason: 'Start work?',
          kind: ApprovalKind.confirmation,
        ),
        ApprovalDecision.allow,
      );
      expect(human.calls, 1);
      expect(judge.calls, 0);
      expect(human.lastKind, ApprovalKind.confirmation);
      mode.mode = PermissionMode.readOnly;
      expect(
        await mode.request(
          operation: 'confirm plan',
          target: 'plan',
          reason: 'Start work?',
          kind: ApprovalKind.confirmation,
        ),
        ApprovalDecision.allow,
      );
      expect(human.calls, 2);
      mode.closeSession();
    },
  );

  test(
    'human-only permission retains Always instead of becoming confirmation',
    () async {
      final human = Human()..answer = ApprovalDecision.allowAlways;
      final judge = Judge(Future.value(const PermissionJudgment(true)));
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: judge,
      );
      expect(
        await mode.request(
          operation: 'deploy',
          target: 'preview',
          reason: 'human consent',
          humanOnly: true,
        ),
        ApprovalDecision.allowAlways,
      );
      expect(human.lastKind, ApprovalKind.permission);
      expect(judge.calls, 0);
      mode.closeSession();
    },
  );

  test(
    'cached execution approval never covers a new network permission or confirmation',
    () async {
      final human = Human();
      final mode = ModePlugin(approvals: human);
      final context = TurnContext(
        CancelToken(),
        input: const Input('run', id: 'run'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
        call: const ToolUse(id: 'exec', name: 'exec', input: {}),
      );
      mode.onInput(context);
      mode.beforeToolCall(context);
      await mode.request(
        operation: 'run command',
        target: 'git',
        reason: 'run',
        context: {
          'required_permissions': ['execution'],
        },
      );
      await mode.request(
        operation: 'run command',
        target: 'git',
        reason: 'network',
        context: {
          'required_permissions': ['execution', 'network'],
        },
      );
      await mode.request(
        operation: 'run command',
        target: 'git',
        reason: 'confirm',
        kind: ApprovalKind.confirmation,
      );
      expect(human.calls, 3);
      expect(human.lastKind, ApprovalKind.confirmation);
      mode.closeSession();
    },
  );

  test(
    'late always approval after cancellation is denied and not cached',
    () async {
      final token = CancelToken();
      final human = Human();
      final pending = Completer<ApprovalDecision>();
      human.pending = pending.future;
      final mode = ModePlugin(approvals: human);
      final context = TurnContext(
        token,
        input: const Input('write', id: 'turn'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
        call: const ToolUse(id: 'write', name: 'write', input: {}),
      );
      mode.onInput(context);
      mode.beforeToolCall(context);
      final result = request(mode);
      token.cancel('cancelled');
      pending.complete(ApprovalDecision.allowAlways);
      expect(await result, ApprovalDecision.deny);
      mode.onTurnEnd(context);
      human.pending = null;
      human.answer = ApprovalDecision.deny;
      final next = TurnContext(
        CancelToken(),
        input: const Input('next', id: 'next'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
        call: context.call,
      );
      mode.onInput(next);
      mode.beforeToolCall(next);
      expect(await request(mode), ApprovalDecision.deny);
      expect(human.calls, 2);
      mode.closeSession();
    },
  );

  test(
    'auto fallback reason travels with the approval instead of only chat',
    () async {
      for (final entry in {
        const PermissionJudgment(false): 'classifier recommends denial',
        const PermissionJudgment(null, 'timed out'): 'classifier timed out',
        const PermissionJudgment(null, 'provider error'):
            'classifier provider error',
        const PermissionJudgment(null, 'unreadable answer'):
            'classifier unreadable answer',
      }.entries) {
        final human = Human();
        final mode = ModePlugin(
          mode: PermissionMode.auto,
          approvals: human,
          classifier: Judge(Future.value(entry.key)),
        );
        await request(mode);
        expect(
          human.lastReason,
          'Auto approval: ${entry.value}. approval required',
        );
        expect(human.lastDetails['auto_approval_fallback'], entry.value);
        expect(human.lastDetails['mode'], 'auto');
        mode.closeSession();
      }
    },
  );

  test(
    'classifier model and response counts follow the human fallback',
    () async {
      final human = Human();
      const diagnostics = {
        'model': 'provider/current-model',
        'attempts': 2,
        'answer_characters': 0,
        'reasoning_characters': 1400,
        'stop_reason': 'stop',
      };
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: Judge(
          Future.value(
            const PermissionJudgment(null, 'returned no verdict', diagnostics),
          ),
        ),
      );
      expect(await request(mode), ApprovalDecision.allow);
      expect(
        human.lastReason,
        contains('returned no verdict (provider/current-model)'),
      );
      expect(human.lastDetails['auto_approval_classifier'], diagnostics);
      expect(human.calls, 1);
      mode.closeSession();
    },
  );

  test(
    'a classifier denial explains the risk and still asks the human',
    () async {
      const risk = 'Force pushing can overwrite remote history.';
      final human = Human()..answer = ApprovalDecision.deny;
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: Judge(Future.value(const PermissionJudgment.denied(risk))),
      );
      expect(await request(mode), ApprovalDecision.deny);
      expect(human.calls, 1);
      expect(human.lastReason, contains('classifier recommends denial: $risk'));
      expect(human.lastReason, isNot(contains('..')));
      expect(human.lastDetails['auto_approval_denial_reason'], risk);
      human.answer = ApprovalDecision.allow;
      expect(await request(mode), ApprovalDecision.allow);
      expect(
        human.calls,
        2,
        reason: 'a DENY verdict cannot remember permission',
      );
      mode.closeSession();
    },
  );

  test(
    'human receives full tool context and allow once expires with invocation',
    () async {
      final human = Human();
      final mode = ModePlugin(approvals: human);
      final context = TurnContext(
        CancelToken(),
        input: const Input('write', id: 'turn'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
        call: const ToolUse(
          id: 'write',
          name: 'write',
          input: {'filePath': '/outside/result', 'content': 'hello'},
        ),
      );
      mode.onInput(context);
      mode.beforeToolCall(context);
      Future<ApprovalDecision> write(String target) => mode.request(
        operation: 'write',
        target: target,
        reason: 'ask',
        context: {'workspace': '/project'},
      );
      expect(await write('/outside/result'), ApprovalDecision.allow);
      expect(await write('/outside/.temp'), ApprovalDecision.allow);
      expect(human.calls, 1);
      expect((human.lastDetails['tool'] as Map)['input'], context.call!.input);
      expect(human.lastDetails['workspace'], '/project');
      mode.afterToolResult(context);
      mode.beforeToolCall(context);
      await write('/outside/result');
      expect(human.calls, 2);
      mode.mode = PermissionMode.readOnly;
      expect(await write('/outside/result'), ApprovalDecision.deny);
      expect(human.calls, 2);
      mode.closeSession();
    },
  );
  test('selectable modes share command vocabulary and cycle order', () async {
    final mode = ModePlugin();
    const selectable = [
      PermissionMode.ask,
      PermissionMode.readOnly,
      PermissionMode.allowEdits,
      PermissionMode.auto,
    ];
    expect(ModePlugin.modeWords, ['ask', 'read-only', 'allow-edits', 'auto']);
    for (final value in selectable) {
      expect(mode.mode, value);
      mode.mode = mode.mode.next;
    }
    expect(mode.mode, PermissionMode.ask);
    for (final value in selectable) {
      await mode.commands.single.handler(value.label);
      expect(mode.mode, value);
    }
    expect(ModePlugin.parseMode('normal'), isNull);
    expect(ModePlugin.parseMode('yolo'), isNull);
  });

  test(
    'manual modes use human review; read-only blocks unconfined execution',
    () async {
      for (final value in [
        PermissionMode.ask,
        PermissionMode.readOnly,
        PermissionMode.allowEdits,
      ]) {
        final human = Human();
        final judge = Judge(Future.value(const PermissionJudgment(true)));
        final mode = ModePlugin(
          mode: value,
          approvals: human,
          classifier: judge,
        );
        expect(
          await request(mode),
          value == PermissionMode.readOnly
              ? ApprovalDecision.deny
              : ApprovalDecision.allow,
        );
        expect(human.calls, value == PermissionMode.readOnly ? 0 : 1);
        expect(judge.calls, 0);
      }
    },
  );

  test('auto allows once; denial, errors and no judge ask the human', () async {
    final human = Human();
    final mode = ModePlugin(mode: PermissionMode.auto, approvals: human);
    mode.classifier = Judge(Future.value(const PermissionJudgment(true)));
    expect(await request(mode), ApprovalDecision.allow);
    expect(human.calls, 0);
    for (final judgment in [
      const PermissionJudgment(false),
      const PermissionJudgment(null, 'timeout'),
    ]) {
      mode.classifier = Judge(Future.value(judgment));
      human.answer = ApprovalDecision.deny;
      expect(await request(mode), ApprovalDecision.deny);
    }
    mode.classifier = null;
    expect(await request(mode), ApprovalDecision.deny);
    expect(human.calls, 3);
  });

  test(
    'read-only refuses mutation requests before human or automatic review',
    () async {
      final human = Human();
      final judge = Judge(Future.value(const PermissionJudgment(true)));
      final mode = ModePlugin(
        mode: PermissionMode.readOnly,
        approvals: human,
        classifier: judge,
      );
      expect(await request(mode), ApprovalDecision.deny);
      human.answer = ApprovalDecision.deny;
      expect(await request(mode), ApprovalDecision.deny);
      expect(human.calls, 0);
      expect(judge.calls, 0);
    },
  );

  for (final action in ['cancel', 'read-only', 'close', 'end', 'ask']) {
    test('late automatic ALLOW respects $action', () async {
      final pending = Completer<PermissionJudgment>();
      final human = Human();
      final mode = ModePlugin(
        mode: PermissionMode.auto,
        approvals: human,
        classifier: Judge(pending.future),
      );
      final token = CancelToken();
      final context = TurnContext(
        token,
        input: Input('test', id: 'test'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
      );
      mode.onInput(context);
      final result = request(mode);
      switch (action) {
        case 'cancel':
          token.cancel('escape');
        case 'read-only':
          mode.mode = PermissionMode.readOnly;
        case 'close':
          mode.closeSession();
        case 'end':
          mode.onTurnEnd(context);
        case 'ask':
          mode.mode = PermissionMode.ask;
      }
      pending.complete(const PermissionJudgment(true));
      expect(
        await result,
        action == 'ask' ? ApprovalDecision.allow : ApprovalDecision.deny,
      );
      expect(human.calls, action == 'ask' ? 1 : 0);
    });
  }
}

void precedentTests() {
  const scope = PrecedentScope(workspace: '/work/project');
  Map<String, Object?> commandContext({
    List<String> arguments = const ['status', '--short'],
    List<String> permissions = const ['execution'],
    String accessKind = 'read',
    String coverage = 'complete',
  }) => {
    'executable': '/usr/bin/git',
    'arguments': arguments,
    'required_permissions': permissions,
    'access_coverage': coverage,
    'access_coverage_source': 'verified',
    'accesses': [
      {
        'operation': accessKind,
        'path': '/work/project/a',
        'target_kind': 'file',
        'source': 'verified',
      },
    ],
  };
  Future<ApprovalDecision> run(
    ModePlugin mode, {
    Map<String, Object?>? context,
  }) => mode.request(
    operation: 'run command',
    target: 'git status',
    reason: 'approval required',
    context: context ?? commandContext(),
  );

  test('a human decision is remembered; a denial poisons the shape', () async {
    final store = MemoryPrecedentStore();
    final human = Human();
    final mode = ModePlugin(mode: PermissionMode.auto, approvals: human)
      ..precedentStore = store
      ..precedentScope = () => scope;

    human.answer = ApprovalDecision.allowAlways;
    expect(await run(mode), ApprovalDecision.allowAlways);
    final learned = store.read().single;
    expect(learned.outcome, PrecedentOutcome.allow);
    expect(learned.authority, PrecedentAuthority.humanAlways);
    expect(learned.count, 1);

    human.answer = ApprovalDecision.deny;
    await run(mode);
    final poisoned = store.read().single;
    expect(poisoned.conflicted, true);
    expect(
      poisoned.outcome,
      PrecedentOutcome.allow,
      reason: 'the first recorded outcome is retained',
    );
  });

  test('an exact read-only shape runs quietly after two approvals', () async {
    final store = MemoryPrecedentStore();
    final human = Human();
    final judge = Judge(Future.value(const PermissionJudgment(null, 'unused')));
    final mode =
        ModePlugin(
            mode: PermissionMode.auto,
            approvals: human,
            classifier: judge,
          )
          ..precedentStore = store
          ..readPrecedentMode = (() => PrecedentMode.full)
          ..precedentScope = (() => scope);

    // Nothing learned yet: the judge denies, the human allows.
    for (var i = 0; i < 2; i++) {
      human.answer = ApprovalDecision.allow;
      await run(mode);
    }
    expect(store.read().single.count, 2);
    human.calls = 0;
    judge.calls = 0;

    expect(await run(mode), ApprovalDecision.allow);
    expect(human.calls, 0, reason: 'the third ask must not reach the human');
    expect(judge.calls, 0, reason: 'the third ask must not reach the model');
  });

  test('the fast path never covers network or partial access', () async {
    for (final context in [
      commandContext(permissions: ['execution', 'network']),
      commandContext(coverage: 'partial'),
      commandContext(accessKind: 'write'),
    ]) {
      final store = MemoryPrecedentStore();
      final human = Human();
      final mode = ModePlugin(mode: PermissionMode.auto, approvals: human)
        ..precedentStore = store
        ..readPrecedentMode = (() => PrecedentMode.full)
        ..precedentScope = (() => scope);
      for (var i = 0; i < 3; i++) {
        human.answer = ApprovalDecision.allow;
        await run(mode, context: context);
      }
      human.calls = 0;
      await run(mode, context: context);
      expect(human.calls, 1, reason: 'context: $context must keep asking');
    }
  });

  test('evidence mode exposes ranked precedents; off exposes none', () async {
    final store = MemoryPrecedentStore();
    final human = Human();
    final mode = ModePlugin(mode: PermissionMode.auto, approvals: human)
      ..precedentStore = store
      ..precedentScope = () => scope;
    human.answer = ApprovalDecision.allow;
    await run(mode);

    final evidence = mode.precedentEvidenceFor({
      'operation': 'run command',
      'tool': {'name': 'exec'},
      ...commandContext(),
    });
    expect(evidence, hasLength(1));
    expect(evidence.single['outcome'], 'allow');

    mode.readPrecedentMode = () => PrecedentMode.off;
    expect(
      mode.precedentEvidenceFor({
        'operation': 'run command',
        'tool': {'name': 'exec'},
        ...commandContext(),
      }),
      isEmpty,
    );
  });
}

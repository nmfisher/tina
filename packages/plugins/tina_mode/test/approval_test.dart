import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart';

class Human implements ApprovalRequester {
  int calls = 0;
  Map<String, Object?> lastDetails = {};
  String lastReason = '';
  ApprovalDecision answer = ApprovalDecision.allow;
  @override
  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    ApprovalKind kind = ApprovalKind.permission,
    Map<String, Object?> details = const {},
  }) async {
    calls++;
    lastDetails = details;
    lastReason = reason;
    return answer;
  }
}

class Judge extends PermissionClassifier {
  Judge(this.result) : super(() => throw StateError('unused'));
  final Future<PermissionJudgment> result;
  int calls = 0;
  @override
  Future<PermissionJudgment> classify(
    Map<String, Object?> request, {
    Future<void>? whenCancelled,
  }) {
    calls++;
    return result;
  }
}

Future<ApprovalDecision> request(ModePlugin mode) => mode.request(
  operation: 'run command',
  target: 'git status',
  reason: 'approval required',
);

void main() {
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
      mode.closeSession();
    },
  );
  test('all four modes share command vocabulary and cycle order', () async {
    final mode = ModePlugin();
    expect(ModePlugin.modeWords, ['ask', 'read-only', 'allow-edits', 'auto']);
    for (final value in PermissionMode.values) {
      expect(mode.mode, value);
      mode.mode = mode.mode.next;
    }
    expect(mode.mode, PermissionMode.ask);
    for (final value in PermissionMode.values) {
      await mode.commands.single.handler(value.label);
      expect(mode.mode, value);
    }
    expect(ModePlugin.parseMode('normal'), isNull);
  });

  test(
    'ask and allow-edits send approval requests to the human, not the judge',
    () async {
      for (final value in [PermissionMode.ask, PermissionMode.allowEdits]) {
        final human = Human();
        final judge = Judge(Future.value(const PermissionJudgment(true)));
        final mode = ModePlugin(
          mode: value,
          approvals: human,
          classifier: judge,
        );
        expect(await request(mode), ApprovalDecision.allow);
        expect(human.calls, 1);
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

  test('read-only never consults judge or human', () async {
    final human = Human();
    final judge = Judge(Future.value(const PermissionJudgment(true)));
    final mode = ModePlugin(
      mode: PermissionMode.readOnly,
      approvals: human,
      classifier: judge,
    );
    expect(await request(mode), ApprovalDecision.deny);
    expect(human.calls, 0);
    expect(judge.calls, 0);
  });

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

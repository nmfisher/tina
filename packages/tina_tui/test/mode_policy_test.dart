import 'dart:io';
import 'package:tina_plans/tina_plans.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_approvals/tina_approvals.dart' as approvals;

void main() {
  test(
      'read-only approval remembers only the chosen file and permits a later edit',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-read-only-grants-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final human = _Human();
    final assembly = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: '${dir.path}/missing', workingDirectory: dir.path),
        providerFactory: (_) => ScriptedProvider([
              scriptedReply('', calls: const [
                ToolUseBlock(
                    id: 'first',
                    name: 'write',
                    input: {'filePath': 'approved.txt', 'content': 'one'}),
                ToolUseBlock(id: 'edit', name: 'edit', input: {
                  'filePath': 'approved.txt',
                  'oldString': 'one',
                  'newString': 'two'
                }),
                ToolUseBlock(
                    id: 'other',
                    name: 'write',
                    input: {'filePath': 'other.txt', 'content': 'no'}),
              ]),
              scriptedReply('finished'),
            ]));
    addTearDown(assembly.close);
    assembly.tools.modePolicy.approvals = human;
    await assembly.handleCommand('/mode read-only');
    await assembly.host.send('review writes');
    expect(human.targets.map((path) => path.split('/').last),
        ['approved.txt', 'other.txt']);
    expect(human.modes, ['readOnly', 'readOnly']);
    expect(File('${dir.path}/approved.txt').readAsStringSync(), 'two');
    expect(File('${dir.path}/other.txt').existsSync(), false);
    expect(assembly.tools.mode.label, 'read-only');
    final results = assembly.host.session.loop.log
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolResultBlock>()
        .toList();
    expect(results.map((r) => r.isError), [false, false, true]);
  });

  test('auto never substitutes classifier consent for plan approval', () async {
    final dir = Directory.systemTemp.createTempSync('tina-mode-plan-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final agent = ScriptedProvider([
      scriptedReply('', calls: [
        ToolUseBlock(id: 'plan', name: 'update_plan', input: {
          'items': [
            {'text': 'the work', 'state': 'pending'}
          ],
          'approval': 'requested',
        })
      ]),
      scriptedReply('finished'),
    ]);
    var builds = 0;
    final assembly = TuiAssembly.start(
      options: AssemblyOptions(
          configPath: '${dir.path}/missing', workingDirectory: dir.path),
      providerFactory: (_) {
        builds++;
        return agent;
      },
    );
    addTearDown(assembly.close);
    await assembly.handleCommand('/mode auto');
    await assembly.host.send('plan the work');
    expect(builds, 1, reason: 'only the conversation model was called');
    expect(
        assembly.host.session.loop.log
            .whereType<PluginStateEntry>()
            .where(PlanChangedEntry.matches)
            .map(PlanChangedEntry.decode)
            .last
            .approval,
        PlanApproval.rejected);
  });

  for (final mode in ['ask', 'read-only', 'allow-edits', 'auto']) {
    test(
        '$mode controls a real project write through the registered mode plugin',
        () async {
      final dir = Directory.systemTemp.createTempSync('tina-mode-write-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final judgeRequests = <String>[];
      final agent = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'w', name: 'write', input: {
            'filePath': 'result.txt',
            'content': 'classified contents'
          })
        ]),
        scriptedReply('finished'),
      ]);
      var builds = 0;
      final assembly = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: '${dir.path}/missing', workingDirectory: dir.path),
        providerFactory: (_) => builds++ == 0 ? agent : _Judge(judgeRequests),
      );
      addTearDown(assembly.close);
      expect(assembly.host.plugins.where((p) => p.id == 'tina/mode'),
          hasLength(1));
      expect(assembly.host.plugins.any((p) => p.id == 'tina/mode-tui'), false);
      await assembly.handleCommand('/mode $mode');
      await assembly.host.send('write result');
      expect(File('${dir.path}/result.txt').existsSync(),
          mode == 'allow-edits' || mode == 'auto');
      if (mode == 'auto') {
        expect(judgeRequests, isNotEmpty);
        expect(judgeRequests.every((r) => r.contains('classified contents')),
            true);
        // Safety review usage is included in the session's persisted ledger.
        final usage =
            assembly.host.session.loop.log.whereType<UsageRecordedEntry>();
        expect(usage.any((e) => !e.child && e.usage.outputTokens == 7), true);
      } else {
        expect(judgeRequests, isEmpty);
      }
    });
  }
}

class _Human implements approvals.ApprovalRequester {
  final targets = <String>[];
  final modes = <String>[];
  @override
  Future<approvals.ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      approvals.ApprovalKind kind = approvals.ApprovalKind.permission,
      Map<String, Object?> details = const {}}) async {
    targets.add(target);
    modes.add(details['mode'] as String);
    return target.endsWith('/approved.txt')
        ? approvals.ApprovalDecision.allowAlways
        : approvals.ApprovalDecision.deny;
  }
}

class _Judge extends LlmProvider {
  _Judge(this.requests) : super('judge');
  final List<String> requests;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(messages.single.content
        .whereType<TextBlock>()
        .map((b) => b.text)
        .join());
    yield const MessageComplete(
        content: [TextBlock('ALLOW')],
        stopReason: 'end_turn',
        usage: TokenUsage(inputTokens: 10, outputTokens: 7));
  }
}

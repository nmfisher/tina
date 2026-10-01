import 'dart:io';
import 'dart:convert';
import 'package:tina_tools/tina_tools.dart' show ProcessPermission;
import 'package:tina_plans/tina_plans.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_approvals/tina_approvals.dart' as approvals;

void main() {
  test(
      'auto routes outside-sandbox execution to human and remembers exact grant',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-outside-human-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final judgeRequests = <String>[];
    final human = _NetworkHuman();
    final agent = ScriptedProvider([
      scriptedReply('', calls: const [
        ToolUseBlock(id: 'first', name: 'exec', input: {
          'program': '/bin/echo',
          'args': ['outside approved'],
          'outside_sandbox': true,
          'sandbox_reason': 'hidden host program',
        }),
        ToolUseBlock(id: 'repeat', name: 'exec', input: {
          'program': '/bin/echo',
          'args': ['outside approved'],
          'outside_sandbox': true,
          'sandbox_reason': 'hidden host program',
        }),
      ]),
      scriptedReply('finished'),
    ]);
    var builds = 0;
    final assembly = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: '${dir.path}/missing', workingDirectory: dir.path),
        providerFactory: (_) => builds++ == 0 ? agent : _Judge(judgeRequests));
    addTearDown(assembly.close);
    assembly.tools.modePolicy.approvals = human;
    await assembly.handleCommand('/mode auto');
    await assembly.host.send('run outside');
    expect(judgeRequests, isEmpty);
    expect(human.kinds.single, approvals.ApprovalKind.permission);
    final details = human.requests.single;
    expect(details['required_permissions'],
        ['execution', 'network', 'unconfined']);
    expect(details['sandbox_reason'], 'hidden host program');
    expect(
        (details['description'] as Map)['title'], contains('outside sandbox'));
    expect(
        (details['description'] as Map)['fields'],
        containsPair(
            'Access', 'Host filesystem and network for this subprocess tree'));
    final results = assembly.host.session.loop.log
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolResultBlock>()
        .toList();
    expect(results, hasLength(2));
    expect(
        results
            .every((r) => !r.isError && r.content.contains('outside approved')),
        true);
  });

  for (final answer in ['ALLOW', 'DENY', 'unreadable']) {
    test('auto reviews network with execution: $answer', () async {
      final dir = Directory.systemTemp.createTempSync('tina-auto-network-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final judgeRequests = <String>[];
      final human = _NetworkHuman();
      final agent = ScriptedProvider([
        scriptedReply('', calls: [
          for (final id in ['first', 'second'])
            ToolUseBlock(id: id, name: 'exec', input: const {
              'program': '/bin/echo',
              'args': ['network reviewed'],
              'network': true,
              'network_reason': 'test network action',
            }),
        ]),
        scriptedReply('finished'),
      ]);
      var builds = 0;
      final assembly = TuiAssembly.start(
          options: AssemblyOptions(
              configPath: '${dir.path}/missing', workingDirectory: dir.path),
          providerFactory: (_) =>
              builds++ == 0 ? agent : _Judge(judgeRequests, answer: answer));
      addTearDown(assembly.close);
      assembly.tools.modePolicy.approvals = human;
      await assembly.handleCommand('/mode auto');
      await assembly.host.send('run network commands');
      final automatic = answer == 'ALLOW';
      expect(
          judgeRequests, hasLength(automatic || answer == 'unreadable' ? 2 : 1),
          reason: 'automatic consent expires; human Always is a session grant');
      if (answer == 'unreadable') {
        expect(judgeRequests[1], judgeRequests[0],
            reason: 'the retry reviews the same invocation and permissions');
        expect(human.requests.single['auto_approval_classifier'],
            containsPair('attempts', 2));
      }
      final judged = jsonDecode(judgeRequests.first) as Map;
      expect(judged['required_permissions'], ['execution', 'network']);
      expect(judged['missing_permissions'], ['execution', 'network']);
      expect(judged['executable'], '/bin/echo');
      expect(judged['arguments'], ['network reviewed']);
      expect(judged['network_reason'], 'test network action');
      expect((judged['tool'] as Map)['input']['network'], true);
      expect(human.requests, hasLength(automatic ? 0 : 1));
      if (!automatic) {
        expect(human.kinds.single, approvals.ApprovalKind.permission);
        expect(human.requests.single['required_permissions'],
            ['execution', 'network']);
        expect(human.requests.single['auto_approval_fallback'],
            contains('classifier'));
      }
      expect(assembly.tools.processRunner.grants.isEmpty, automatic);
      final results = assembly.host.session.loop.log
          .whereType<MessageAppendedEntry>()
          .expand((e) => e.message.content)
          .whereType<ToolResultBlock>()
          .toList();
      expect(results, hasLength(2));
      expect(results.every((result) => !result.isError), true);
      expect(results.last.content, contains('network reviewed'));
    });
  }

  test('auto reviews network even when execution already has a session grant',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-network-extra-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final judgeRequests = <String>[];
    final agent = ScriptedProvider([
      scriptedReply('', calls: const [
        ToolUseBlock(id: 'fetch', name: 'exec', input: {
          'program': '/bin/echo',
          'args': ['network reviewed'],
          'network': true,
          'network_reason': 'test network action',
        })
      ]),
      scriptedReply('finished'),
    ]);
    var builds = 0;
    final assembly = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: '${dir.path}/missing', workingDirectory: dir.path),
        providerFactory: (_) => builds++ == 0 ? agent : _Judge(judgeRequests));
    addTearDown(assembly.close);
    final request = (
      command: '/bin/echo',
      arguments: ['network reviewed'],
      workingDirectory: assembly.tools.workingDirectory,
      environment: null,
      stdin: null,
      timeout: null,
    );
    assembly.tools.processRunner.grants.rememberRequest(request);
    await assembly.handleCommand('/mode auto');
    await assembly.host.send('run with network');
    expect(judgeRequests, hasLength(1));
    final judged = jsonDecode(judgeRequests.single) as Map;
    expect(judged['required_permissions'], ['execution', 'network']);
    expect(judged['missing_permissions'], ['network']);
    expect(
        assembly.tools.processRunner.grants
            .coversRequest(request, permission: ProcessPermission.network),
        false);
  });

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

class _Judge extends LlmProvider implements StructuredOutputProvider {
  _Judge(this.requests, {this.answer = 'ALLOW'}) : super('judge');
  final List<String> requests;
  final String answer;
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      throw StateError('judge must use structured output');
  @override
  Stream<StreamEvent> sendStructured(
      {required String system,
      required List<Message> messages,
      required JsonOutputSchema output}) async* {
    requests.add(messages.single.content
        .whereType<TextBlock>()
        .map((b) => b.text)
        .join());
    yield MessageComplete(
        content: [
          TextBlock(answer == 'unreadable'
              ? answer
              : jsonEncode({
                  'decision': answer,
                  'reason': answer == 'DENY'
                      ? 'This operation can delete project data.'
                      : ''
                }))
        ],
        stopReason: 'end_turn',
        usage: TokenUsage(inputTokens: 10, outputTokens: 7));
  }
}

class _NetworkHuman implements approvals.ApprovalRequester {
  final requests = <Map<String, Object?>>[];
  final kinds = <approvals.ApprovalKind>[];
  @override
  Future<approvals.ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    approvals.ApprovalKind kind = approvals.ApprovalKind.permission,
    Map<String, Object?> details = const {},
  }) async {
    requests.add(details);
    kinds.add(kind);
    return approvals.ApprovalDecision.allowAlways;
  }
}

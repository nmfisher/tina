import 'dart:io';
import 'dart:convert';
import 'package:tina_plans/tina_plans.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'package:tina_approvals/tina_approvals.dart' as approvals;

void main() {
  for (final mode in ['approve', 'auto']) {
    test('$mode asks a human once for all workspace writes', () async {
      final root = Directory.systemTemp.createTempSync('tina-root-write-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/source').writeAsStringSync('readable');
      final reviews = <String>[];
      final human = _NetworkHuman();
      final actor = ScriptedProvider([
        scriptedReply(
          '',
          calls: const [
            ToolUseBlock(id: 'r', name: 'read', input: {'filePath': 'source'}),
            ToolUseBlock(
              id: 'w1',
              name: 'write',
              input: {'filePath': 'first', 'content': 'one'},
            ),
            ToolUseBlock(
              id: 'w2',
              name: 'write',
              input: {'filePath': 'second', 'content': 'two'},
            ),
          ],
        ),
        scriptedReply('done'),
      ]);
      var builds = 0;
      final app = SessionAssembly.start(
        options: AssemblyOptions(
          configPath: '${root.path}/missing',
          workingDirectory: root.path,
        ),
        providerFactory: (_) => builds++ == 0 ? actor : _Judge(reviews),
      );
      addTearDown(app.close);
      final initialGrants = app.tools.commandApprovals.entries;
      app.tools.modePolicy.approvals = human;
      await app.handleCommand('/mode $mode');
      await app.host.send('read and write files');
      expect(reviews, isEmpty);
      expect(human.requests, hasLength(1));
      expect(human.requests.single['workspace_write_grant'], true);
      expect(File('${root.path}/first').readAsStringSync(), 'one');
      expect(File('${root.path}/second').readAsStringSync(), 'two');
      expect(app.tools.commandApprovals.entries, initialGrants);
      // Changing modes does not revoke the session's human grant.
      await app.handleCommand('/mode ${mode == 'auto' ? 'approve' : 'auto'}');
      await app.tools.sandbox.writeFile('${root.path}/third', 'three');
      expect(human.requests, hasLength(1));
    });
  }

  // Owner ruling 2026-11-17 (v0.10.2 judge policy confirmed):
  // 1. external reads are JUDGED, never auto-denied — the model is
  //    consulted even when it will deny;
  // 2. secret/credential-shaped exposure is what the judge denies (the
  //    no-secrets condition in the reviewer prompt, unchanged);
  // 3. a judge DENY is a recommendation: it surfaces to the human as an
  //    approval dialog carrying the judge's reason — the user decides.
  for (final answer in ['ALLOW', 'DENY', 'UNCERTAIN', 'unreadable']) {
    // Every non-ALLOW verdict reaches the human, so the human's stance
    // decides both ways for all of them; ALLOW never asks, one variant.
    for (final humanAllows in answer == 'ALLOW' ? [true] : [true, false]) {
      test('auto routes external reads through the model: $answer'
          '${answer == 'ALLOW' ? '' : ', human ${humanAllows ? 'allows' : 'refuses'}'}',
          () async {
        final root = Directory.systemTemp.createTempSync('tina-external-review-');
        addTearDown(() => root.deleteSync(recursive: true));
        final workspace = Directory('${root.path}/workspace')..createSync();
        final external = File('${root.path}/external')
          ..writeAsStringSync('contents');
        final reviews = <String>[];
        final human = _NetworkHuman()
          ..answer = humanAllows
              ? approvals.ApprovalDecision.allow
              : approvals.ApprovalDecision.deny;
        final actor = ScriptedProvider([
          scriptedReply(
            '',
            calls: [
              for (final id in ['r1', 'r2'])
                ToolUseBlock(
                  id: id,
                  name: 'read',
                  input: {'filePath': external.path},
                ),
            ],
          ),
          scriptedReply('done'),
        ]);
        var builds = 0;
        final app = SessionAssembly.start(
          options: AssemblyOptions(
            configPath: '${root.path}/missing',
            workingDirectory: workspace.path,
          ),
          providerFactory: (_) =>
              builds++ == 0 ? actor : _Judge(reviews, answer: answer),
        );
        addTearDown(app.close);
        final initialGrants = app.tools.commandApprovals.entries;
        app.tools.modePolicy.approvals = human;
        await app.handleCommand('/mode auto');
        await app.host.send('read the external file twice');
        expect(
          reviews,
          hasLength(answer == 'unreadable' ? 4 : 2),
          reason:
              'model approval is invocation only; malformed responses get one retry',
        );
        // The judge consulted: an external read is judged, not silently
        // blocked. Every non-ALLOW verdict (and only those) reach a human.
        expect(
          human.requests,
          hasLength(['DENY', 'UNCERTAIN', 'unreadable'].contains(answer) ? 2 : 0),
        );
        if (answer == 'DENY') {
          // The judge's denial travels to the user dialog, reason attached.
          expect(
            human.requests.every((details) =>
                details['auto_approval_denial_reason'] ==
                'This operation can delete project data.'),
            true,
          );
          expect(
            human.requests.every((details) =>
                (details['approval_reason_codes'] as List)
                    .contains('classifier_denial')),
            true,
          );
        }
        final results = app.host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .expand((e) => e.message.content)
            .whereType<ToolResultBlock>()
            .toList();
        expect(results, hasLength(2));
        // The human decides: an allowed denial proceeds, a refused one errors.
        final refused = answer != 'ALLOW' && !humanAllows;
        expect(results.every((r) => r.isError == refused), true);
        expect(app.tools.commandApprovals.entries, initialGrants);
        expect(
          app.host.session.loop.log.whereType<UsageRecordedEntry>().any(
            (e) => !e.child && e.usage.outputTokens == 7,
          ),
          true,
        );
      });
    }
  }

  test('auto never substitutes classifier consent for plan approval', () async {
    final dir = Directory.systemTemp.createTempSync('tina-mode-plan-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final agent = ScriptedProvider([
      scriptedReply(
        '',
        calls: [
          ToolUseBlock(
            id: 'plan',
            name: 'update_plan',
            input: {
              'items': [
                {'text': 'the work', 'state': 'pending'},
              ],
              'approval': 'requested',
            },
          ),
        ],
      ),
      scriptedReply('finished'),
    ]);
    var builds = 0;
    final assembly = SessionAssembly.start(
      options: AssemblyOptions(
        configPath: '${dir.path}/missing',
        workingDirectory: dir.path,
      ),
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
      PlanApproval.rejected,
    );
  });
}

class _Judge extends LlmProvider implements StructuredOutputProvider {
  _Judge(this.requests, {this.answer = 'ALLOW'}) : super('judge');
  final List<String> requests;
  final String answer;
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) => throw StateError('judge must use structured output');
  @override
  Stream<StreamEvent> sendStructured({
    required String system,
    required List<Message> messages,
    required JsonOutputSchema output,
  }) async* {
    requests.add(
      messages.single.content.whereType<TextBlock>().map((b) => b.text).join(),
    );
    yield MessageComplete(
      content: [
        TextBlock(
          answer == 'unreadable'
              ? answer
              : jsonEncode({
                  'decision': answer,
                  'reason': answer == 'DENY'
                      ? 'This operation can delete project data.'
                      : '',
                }),
        ),
      ],
      stopReason: 'end_turn',
      usage: TokenUsage(inputTokens: 10, outputTokens: 7),
    );
  }
}

class _NetworkHuman implements approvals.ApprovalRequester {
  final requests = <Map<String, Object?>>[];
  final kinds = <approvals.ApprovalKind>[];
  approvals.ApprovalDecision answer = approvals.ApprovalDecision.allow;
  @override
  Future<approvals.ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    approvals.ApprovalKind kind = approvals.ApprovalKind.permission,
    Future<void>? whenCancelled,
    Map<String, Object?> details = const {},
    void Function(String pattern)? onCommandPattern,
    void Function(List<approvals.DirectoryAccessGrant> grants)?
    onDirectoryGrants,
  }) async {
    requests.add(details);
    kinds.add(kind);
    return answer;
  }
}

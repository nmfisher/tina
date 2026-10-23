import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test(
    'assembled workspaces discover each other only through approved history tools',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('tina-history-cli-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final config = File('${root.path}/config')
        ..writeAsStringSync('''
[default]
model = "scripted"
[plugins]
enabled = ["tina/persistence"]
''');
      final firstRoot = Directory('${root.path}/first')..createSync();
      final secondRoot = Directory('${root.path}/second')..createSync();
      SessionAssembly start(Directory workspace, ScriptedProvider provider) =>
          SessionAssembly.start(
            providerFactory: (_) => provider,
            options: AssemblyOptions(
              configPath: config.path,
              workingDirectory: workspace.path,
              osSandbox: true,
            ),
          );
      final first = start(
        firstRoot,
        ScriptedProvider([scriptedReply('prior answer')]),
      );
      await first.host.send('workspace first historical phrase');
      final previousId = first.host.session.id;
      first.close();
      final provider = ScriptedProvider([
        scriptedReply(
          '',
          calls: [
            const ToolUseBlock(
              id: 'history',
              name: 'search_sessions',
              input: {'query': 'historical phrase', 'scope': 'global'},
            ),
          ],
        ),
        scriptedReply('Found it'),
      ]);
      final second = start(secondRoot, provider);
      addTearDown(second.close);
      final channel = StreamApprovalChannel();
      final approvals = ApprovalsPlugin(channel: channel);
      final requests = <ApprovalRequest>[];
      final subscription = channel.requests.listen((request) {
        requests.add(request);
        channel.respond(request.id, ApprovalDecision.allow);
      });
      addTearDown(() async {
        approvals.closeSession();
        channel.closeSession();
        await subscription.cancel();
      });
      second.tools.modePolicy.approvals = approvals;
      await second.host.send('Find the earlier discussion');
      expect(requests, hasLength(1));
      expect(requests.single.details['permission_scope'], 'session-history');
      final result = second.host.session.loop.log
          .whereType<MessageAppendedEntry>()
          .expand((e) => e.message.content)
          .whereType<ToolResultBlock>()
          .single;
      expect(result.isError, false, reason: result.content);
      final data = jsonDecode(result.content) as Map;
      final match = (data['results'] as List).single;
      expect(match['session_id'], previousId);
      expect(match['workspace'], firstRoot.path);
      expect(match['snippet'], contains('historical phrase'));
      expect(second.tools.sandbox.grants.isEmpty, true);
    },
  );
}

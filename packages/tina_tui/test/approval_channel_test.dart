import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart' hide ApprovalDecision;

void main() {
  late Directory root;
  late Directory workspace;
  late File config;
  setUp(() {
    root = Directory.systemTemp.createTempSync('approval-channel-');
    workspace = Directory('${root.path}/workspace')..createSync();
    config = File('${root.path}/config')..writeAsStringSync('''[default]
model = "scripted"
[plugins]
enabled = []
approval_channel = "acme/messages"
''');
  });
  tearDown(() => root.deleteSync(recursive: true));

  TuiAssembly assemble(StreamApprovalChannel channel, String target) =>
      TuiAssembly.start(
          options: AssemblyOptions(
              configPath: config.path, workingDirectory: workspace.path),
          registerPlugins: (registry) => registry.registerDefinition(
              PluginDefinition<TuiPluginContext>(channel.id, (_) => channel,
                  provides: [approvalChannel])),
          providerFactory: (_) => ScriptedProvider([
                scriptedReply('', calls: [
                  ToolUseBlock(id: 'write', name: 'write', input: {
                    'filePath': target,
                    'content': 'approved remotely'
                  })
                ]),
                scriptedReply('done'),
                scriptedReply('next turn works'),
              ]));

  test(
      'configured third-party stream channel approves a real write without a TUI',
      () async {
    final channel = StreamApprovalChannel(id: 'acme/messages');
    final requests = <ApprovalRequest>[];
    final subscription = channel.requests.listen((request) {
      requests.add(request);
      channel.respond(request.id, ApprovalDecision.allowAlways);
    });
    final target = File('${root.path}/outside');
    final app = assemble(channel, target.path);
    addTearDown(() async {
      app.close();
      await subscription.cancel();
    });
    expect(app.host.config.plugins.any((p) => p.id == 'tina/approvals-tui'),
        false);
    final outcome = await app.host.send('write outside');
    expect(outcome.stopReason, StopReason.complete);
    expect(requests, hasLength(1));
    expect(target.readAsStringSync(), 'approved remotely');
    expect(channel.respond(requests.single.id, ApprovalDecision.allowAlways),
        false);
  });

  test(
      'cancelling a turn awaiting remote approval returns and prevents a late write',
      () async {
    final channel = StreamApprovalChannel(id: 'acme/messages');
    final request = Completer<ApprovalRequest>();
    final subscription = channel.requests.listen(request.complete);
    final target = File('${root.path}/outside');
    final app = assemble(channel, target.path);
    addTearDown(() async {
      app.close();
      await subscription.cancel();
    });
    final turn = app.host.send('write outside');
    final pending = await request.future;
    app.host.session.loop.cancel('user cancelled');
    final outcome = await turn.timeout(const Duration(seconds: 2));
    expect(outcome.stopReason, StopReason.cancelled);
    expect(channel.respond(pending.id, ApprovalDecision.allowAlways), false);
    expect(target.existsSync(), false);
    expect((await app.host.send('hello')).stopReason, StopReason.complete);
  });

  test(
      'unknown and competing channel selections fail before providers are opened',
      () {
    var providers = 0;
    for (final text in [
      '[default]\nmodel="scripted"\n[plugins]\napproval_channel="unknown/channel"\n',
      '[default]\nmodel="scripted"\n[plugins]\nenabled=["tina/approvals-stream"]\n',
    ]) {
      config.writeAsStringSync(text);
      expect(
          () => TuiAssembly.start(
              options: AssemblyOptions(
                  configPath: config.path, workingDirectory: workspace.path),
              providerFactory: (_) {
                providers++;
                return ScriptedProvider([]);
              }),
          throwsArgumentError);
    }
    expect(providers, 0);
  });
}

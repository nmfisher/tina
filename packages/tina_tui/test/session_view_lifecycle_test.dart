import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/src/session_view.dart';
import 'package:tina_tui/tina_tui.dart' hide ApprovalDecision;

import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

/// These tests pin existing view-only detach behavior. Closing the embedded
/// session remains a separate operation; multiple live attachments come later.
void main() {
  late Directory root, workspace;
  setUp(() {
    root = Directory.systemTemp.createTempSync('session-view-lifecycle-');
    workspace = Directory('${root.path}/workspace')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('detaching a view preserves steering, persistence and later rendering',
      () async {
    final provider = ControlledProvider();
    final session = TuiSession.wrap(TuiAssembly.start(
      providerFactory: (_) => provider,
      options: AssemblyOptions(
        configPath: '${root.path}/global',
        workingDirectory: workspace.path,
        plugins: ['tina/chat-tui', 'tina/persistence'],
      ),
    ));
    final view = SessionView(session);
    final first = _Presentation();
    final replacement = _Presentation();
    Future<bool>? turn;
    addTearDown(() async {
      session.cancel();
      if (turn != null) await turn.timeout(const Duration(seconds: 3));
      view.detachConsole();
      session.close();
      replacement.dispose();
      first.dispose();
    });

    view.attachConsole(first.context);
    turn = session.runLine('first input', renderReply: false);
    await waitFor(() => provider.requests.length == 1);
    provider.requests.single.add(const TextDelta('partial first answer'));
    await waitFor(() => first.screen.chat
        .snapshotLines()
        .join('\n')
        .contains('partial first answer'));

    view.detachConsole();
    expect(session.host.session.loop.running, isTrue);
    expect(session.host.session.loop.log.whereType<TurnEndedEntry>(), isEmpty);
    expect(session.offerInput('steered input'), isTrue);
    await waitFor(() => provider.requests.length == 2);
    provider.requests.last.add(const MessageComplete(
      content: [TextBlock('answer while detached')],
      stopReason: 'end_turn',
    ));
    await provider.requests.last.close();
    expect(await turn.timeout(const Duration(seconds: 3)), isFalse);
    expect(session.inputHistory, ['first input', 'steered input']);
    expect(session.host.session.loop.log.whereType<TurnEndedEntry>(),
        hasLength(2));

    final store = SessionStore.open(defaultSessionStorePath(workspace.path));
    try {
      expect(store.checkGaps(session.host.session.id), isEmpty);
      expect(
        store
            .readEntries(session.host.session.id)
            .map((entry) => entry.toJson()),
        session.host.session.loop.log.map((entry) => entry.toJson()),
      );
    } finally {
      store.close();
    }

    view.attachConsole(replacement.context);
    final transcript = replacement.screen.chat.snapshotLines().join('\n');
    expect(transcript, contains('partial first answer'));
    expect(transcript, contains('steered input'));
    expect(transcript, contains('answer while detached'));
  });

  test('detaching a view leaves an external approval active and correlated',
      () async {
    final channel = StreamApprovalChannel(id: 'acme/messages');
    final requested = Completer<ApprovalRequest>();
    final subscription = channel.requests.listen(requested.complete);
    final target = File('${root.path}/outside.txt');
    final session = TuiSession.wrap(TuiAssembly.start(
      providerFactory: (_) => ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'write', name: 'write', input: {
            'filePath': target.path,
            'content': 'approved externally',
          }),
        ]),
        scriptedReply('write finished'),
      ]),
      options: AssemblyOptions(
        configPath: '${root.path}/global',
        workingDirectory: workspace.path,
        plugins: ['tina/chat-tui', 'tina/persistence'],
        approvalChannel: channel.id,
      ),
      registerPlugins: (registry) => registry.registerDefinition(
        PluginDefinition<TuiPluginContext>(channel.id, (_) => channel,
            provides: [approvalChannel], description: 'External test channel.'),
      ),
    ));
    final view = SessionView(session);
    final presentation = _Presentation();
    Future<bool>? turn;
    addTearDown(() async {
      session.cancel();
      if (turn != null) await turn.timeout(const Duration(seconds: 3));
      view.detachConsole();
      session.close();
      await subscription.cancel();
      presentation.dispose();
    });

    view.attachConsole(presentation.context);
    turn = session.runLine('write outside the workspace', renderReply: false);
    final request = await requested.future.timeout(const Duration(seconds: 3));
    expect(target.existsSync(), isFalse);

    view.detachConsole();
    final approvals = session.host.plugins.whereType<ApprovalsPlugin>().single;
    expect(approvals.pending.map((pending) => pending.id), [request.id]);
    expect(session.host.session.loop.running, isTrue);
    expect(target.existsSync(), isFalse);
    expect(channel.respond(request.id, ApprovalDecision.allow), isTrue);

    expect(await turn.timeout(const Duration(seconds: 3)), isFalse);
    expect(target.readAsStringSync(), 'approved externally');
    expect(session.host.session.lastReply, 'write finished');
    expect(approvals.pending, isEmpty);
    expect(channel.respond(request.id, ApprovalDecision.allow), isFalse);
  });
}

final class _Presentation {
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen);
  late final context = ConsoleContext(screen: screen, editor: editor);

  void dispose() {
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

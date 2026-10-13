import 'support/session_connection.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/tui.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mcp_tui/tina_mcp_tui.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

final class _Surface {
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen);
  late final context = ConsoleContext(screen: screen, editor: editor);
  String get transcript => screen.chat.snapshotLines().join('\n');
  void close() {
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

final class _Updates implements UpdateStatusSource {
  int checks = 0;
  @override
  String get currentVersion => 'test';
  @override
  UpdateStatus get status => const UpdateStatus(UpdatePhase.current);
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<void> checkInBackground() async {
    checks++;
  }
}

final class _CombinedPlugin extends AgentPlugin implements ConsoleContribution {
  @override
  String get id => 'extension/combined';
  @override
  void attachConsole(ConsoleContext context) {}
  @override
  void repaintConsole() {}
  @override
  void detachConsole() {}
}

void main() {
  test(
    'observer and controller views share state with independent authority',
    () async {
      final root = Directory.systemTemp.createTempSync('observer-views-');
      addTearDown(() => root.deleteSync(recursive: true));
      final config = File('${root.path}/config')
        ..writeAsStringSync('''
[default]
model = "controlled"
[mcp.servers.private]
url = "https://example.test/mcp?token=secret"
enabled = false
headers = { Authorization = "hidden" }
''');
      final provider = ControlledProvider();
      final session = TuiSession.wrap(
        SessionAssembly.start(
          providerFactory: (_) => provider,
          options: AssemblyOptions(
            configPath: config.path,
            workingDirectory: root.path,
            plugins: [
              'tina/chat-tui',
              'tina/mode',
              'tina/session-controls',
              'tina/approvals-tui',
              'tina/context',
              'tina/context-tui',
              'tina/mcp',
            ],
          ),
        ),
      );
      final observer = session.createView(role: SessionRole.observer);
      final controller = session.createView();
      final readScreen = _Surface(), writeScreen = _Surface();
      addTearDown(() async {
        observer.close();
        controller.close();
        await session.shutdown();
        readScreen.close();
        writeScreen.close();
      });
      observer.attachConsole(readScreen.context);
      final approvalView = observer.contributions
          .whereType<ApprovalView>()
          .single;
      expect(approvalView.asker, isNull);
      final approvals = session.host.plugins
          .whereType<ApprovalsPlugin>()
          .single;
      expect(
        await approvals.request(
          operation: 'run',
          target: 'unattended',
          reason: '',
        ),
        ApprovalDecision.deny,
        reason: 'An observer is not an approval responder',
      );
      controller.attachConsole(writeScreen.context);
      final denied = throwsA(isA<SessionAccessDenied>());
      final mode = observer.contributions.whereType<ModeView>().single.mode;
      final controls = observer.contributions
          .whereType<SessionControlsView>()
          .single
          .controls;
      final mcp = observer.contributions.whereType<McpView>().single.mcp;
      expect(() => mode.mode = PermissionMode.allowEdits, denied);
      expect(
        () => mode.forClient(const ClientAccess()).mode =
            PermissionMode.allowEdits,
        denied,
      );
      await expectLater(controls.select('changed'), denied);
      expect(() => mcp.addLocalServer('blocked'), denied);
      expect(() => mcp.addHttpServer('blocked'), denied);
      expect(() => mcp.setValue('private', 'enabled', true), denied);
      expect(
        () => mcp
            .forClient(const ClientAccess())
            .setValue('private', 'enabled', true),
        denied,
      );
      expect(() => mcp.servers, denied);
      expect(mcp.serverNames, ['private']);
      final saved = config.readAsStringSync();
      final initialMode = mode.mode;
      final marker = File('${root.path}/forbidden');
      for (final command in [
        'hello',
        '/clear',
        '/model other',
        '/mode allow-edits',
        '!touch ${marker.path}',
      ]) {
        await observer.submit(command);
      }
      expect(provider.requests, isEmpty);
      expect(session.host.session.loop.log, isEmpty);
      expect(marker.existsSync(), isFalse);
      expect(mode.mode, initialMode);
      expect(readScreen.transcript, contains('cannot change it'));
      expect(config.readAsStringSync(), saved);
      final question = session.host.questions.ask(
        'Controller response needed\x1b[31m',
      );
      await waitFor(
        () =>
            readScreen.transcript.contains('Waiting for answer:') &&
            writeScreen.context.isReadingKey,
      );
      expect(readScreen.context.isReadingKey, isFalse);
      expect(readScreen.transcript, isNot(contains('\x1b[31m')));
      final id = observer.connection.questions.pending.single.id;
      expect(controller.connection.questions.answer(id, 'continue'), isTrue);
      expect((await question).text, 'continue');
      await waitFor(() => !writeScreen.context.isReadingKey);
      final tickets = <ApprovalQuestion>[];
      final stopTickets = controller.contributions
          .whereType<ApprovalView>()
          .single
          .interaction
          .listen(tickets.add);
      final approval = approvals.request(
        operation: 'read',
        target: '/private\x1b[31m',
        reason: 'test',
      );
      await waitFor(
        () =>
            readScreen.transcript.contains('Approval pending:') &&
            writeScreen.context.isReadingKey,
      );
      expect(readScreen.context.isReadingKey, isFalse);
      expect(readScreen.transcript, isNot(contains('\x1b[31m')));
      tickets.single.respond(ApprovalDecision.deny);
      expect(await approval, ApprovalDecision.deny);
      stopTickets();
      await waitFor(() => !writeScreen.context.isReadingKey);
      final turn = controller.submit('shared input');
      await waitFor(() => provider.requests.isNotEmpty);
      provider.requests.single.add(const TextDelta('shared preview'));
      await waitFor(
        () =>
            readScreen.transcript.contains('shared preview') &&
            writeScreen.transcript.contains('shared preview'),
      );
      observer.cancel();
      expect(session.host.session.loop.running, isTrue);
      expect(observer.offerInput('not accepted'), isFalse);
      await observer.submit('/context');
      expect(
        observer.contributions.whereType<ContextView>().single.isOpen,
        isTrue,
      );
      expect(
        controller.contributions.whereType<ContextView>().single.isOpen,
        isFalse,
      );
      observer.detachConsole();
      observer.attachConsole(readScreen.context);
      expect(
        observer.contributions.whereType<ModeView>().single.mode.canControl,
        isFalse,
      );
      expect(readScreen.transcript, contains('shared preview'));
      controller.close();
      expect(session.host.session.loop.running, isTrue);
      provider.requests.single.add(
        const MessageComplete(
          content: [TextBlock('shared preview completed')],
          stopReason: 'end_turn',
        ),
      );
      await provider.requests.single.close();
      await turn;
      await waitFor(() => readScreen.transcript.contains('completed'));
      await observer.submit('/quit');
      expect(observer.quitRequested, isTrue);
      expect(session.host.session.loop.running, isFalse);
      expect(session.assembly.quitRequested, isFalse);
      observer.close();
      expect(() => mode.mode = initialMode, throwsStateError);
      await expectLater(controls.select('late'), throwsStateError);
    },
  );

  test(
    'observer update views cannot start background work through their source',
    () async {
      final source = _Updates();
      final plugin = PresentationPlugin<UpdateStatusSource>(
        id: 'tina/update-tui',
        source: source,
      );
      final view =
          createConsoleView(
                plugin,
                connection: testConnection(role: SessionRole.observer),
              )
              as UpdateView;
      final surface = _Surface();
      addTearDown(surface.close);
      addTearDown(view.detachConsole);
      view.attachConsole(surface.context);
      expect(source.checks, 0);
      expect(
        view.source.checkInBackground,
        throwsA(isA<SessionAccessDenied>()),
      );
    },
  );

  test(
    'unregistered combined plugins supply no view for either client role',
    () {
      final plugin = _CombinedPlugin();
      expect(
        createConsoleView(
          plugin,
          connection: testConnection(role: SessionRole.observer),
        ),
        isNull,
      );
      expect(createConsoleView(plugin, connection: testConnection()), isNull);
    },
  );
}

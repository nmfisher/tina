import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina_tui/tina_tui.dart' hide ChatView;
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

final class _Client {
  _Client(TuiSession session) : view = session.createView();
  final SessionView view;
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  late final context = ConsoleContext(screen: screen, editor: editor);
  ConsoleAttachment? attachment;
  void attach() => attachment = ConsoleAttachment.attach(view, context);
  void detach() {
    attachment?.dispose();
    attachment = null;
  }

  T feature<T>() => view.contributions.whereType<T>().single;
  String get transcript => screen.chat.snapshotLines().join('\n');
  void dispose() {
    detach();
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tina_views_'));
  tearDown(() => root.deleteSync(recursive: true));

  TuiSession session(LlmProvider provider, {List<String>? plugins}) {
    final assembly = SessionAssembly.start(
        providerFactory: (_) => provider,
        options: AssemblyOptions(
            configPath: '${root.path}/config',
            workingDirectory: root.path,
            plugins: plugins));
    addTearDown(assembly.close);
    return TuiSession.wrap(assembly);
  }

  test('first-party runtime plugins have independent presentation factories',
      () {
    final runtime = session(ScriptedProvider([]));
    var views = 0;
    for (final plugin in runtime.host.plugins) {
      expect(plugin, isNot(isA<ConsoleContribution>()), reason: plugin.id);
      final first = createConsoleView(plugin),
          second = createConsoleView(plugin);
      if (first == null) {
        expect(second, isNull);
        continue;
      }
      views++;
      expect(first, isNot(isA<AgentPlugin>()), reason: plugin.id);
      expect(first, isNot(same(second)), reason: plugin.id);
      first.detachConsole();
      second!.detachConsole();
    }
    expect(views, greaterThanOrEqualTo(6));
  });

  test(
      'two session views keep drafts and folds while direct host turns survive detach',
      () async {
    final provider = ControlledProvider();
    final runtime = session(provider, plugins: [
      'tina/chat-tui',
      'tina/activity-tui',
      'tina/session-controls',
      'tina/context',
      'tina/context-tui'
    ]);
    final first = _Client(runtime)..attach();
    final second = _Client(runtime);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final line = first.editor.readLine('› ');
    first.io.feedBytes('first draft'.codeUnits);
    await waitFor(() => first.editor.draftText == 'first draft');
    final turn = runtime.host.send('run directly');
    await waitFor(() => provider.requests.length == 1);
    provider.requests.single
        .add(const ReasoningDelta('private folding state', startsBlock: true));
    provider.requests.single.add(const ReasoningEnd());
    provider.requests.single.add(const TextDelta('partial response'));
    await waitFor(() => first.transcript.contains('partial response'));
    second.attach();
    expect(second.transcript, contains('partial response'));
    final firstThought =
        first.feature<ChatView>().blocks.where((b) => b.canFold).first;
    final secondThought =
        second.feature<ChatView>().blocks.where((b) => b.canFold).first;
    firstThought.folded = false;
    first.feature<ChatView>().repaintConsole();
    expect(secondThought.folded, true);
    await second.view.submit('/context');
    expect(second.feature<ContextView>().isOpen, true);
    expect(first.feature<ContextView>().isOpen, false);
    first.detach();
    expect(runtime.host.session.loop.inTurn, true);
    runtime.terminal.writeln('shared runtime notice');
    expect(second.transcript, contains('shared runtime notice'));
    provider.requests.single.add(const TextDelta(' finished'));
    provider.requests.single.add(MessageComplete(
        content: [TextBlock('partial response finished')],
        stopReason: 'end_turn'));
    await provider.requests.single.close();
    expect((await turn).stopReason, StopReason.complete);
    expect(second.transcript, contains('finished'));
    expect(
        runtime.host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .last
            .message
            .content
            .whereType<TextBlock>()
            .single
            .text,
        'partial response finished');
    first.attach();
    expect(first.transcript, contains('partial response finished'));
    expect(first.editor.draftText, 'first draft');
    first.io.feedBytes('\r'.codeUnits);
    expect(await line, 'first draft');
  });

  test(
      'live plugin changes reach both views and detach releases only its observer',
      () async {
    final runtime = session(ScriptedProvider([]),
        plugins: ['tina/chat-tui', 'tina/activity-tui']);
    final first = _Client(runtime)..attach(),
        second = _Client(runtime)..attach();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    runtime.assembly.pluginSettings.apply('tina/activity-tui', false,
        PluginScope.session, runtime.assembly.pluginManager);
    expect(runtime.assembly.pluginManager.lastError, isNull);
    expect(first.view.contributions.whereType<ActivityView>(), isEmpty);
    expect(second.view.contributions.whereType<ActivityView>(), isEmpty);
    first.detach();
    runtime.assembly.pluginSettings.apply('tina/activity-tui', true,
        PluginScope.session, runtime.assembly.pluginManager);
    expect(runtime.assembly.pluginManager.lastError, isNull);
    expect(second.feature<ActivityView>(), isNotNull);
    expect(first.view.contributions, isEmpty);
    first.attach();
    expect(first.feature<ActivityView>(),
        isNot(same(second.feature<ActivityView>())));
    runtime.terminal.writeln('notice to both');
    expect(first.transcript, contains('notice to both'));
    expect(second.transcript, contains('notice to both'));
  });
}

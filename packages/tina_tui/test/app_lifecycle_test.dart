import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart';

final class _Io implements Stdio {
  final listening = Completer<void>();
  late final input = StreamController<List<int>>.broadcast(onListen: () {
    if (!listening.isCompleted) listening.complete();
  });
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String text) {}
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class _Provider implements LlmProvider {
  final started = Completer<void>();
  final events = StreamController<StreamEvent>();
  int closes = 0;
  @override
  String get model => 'controlled';
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    started.complete();
    return events.stream;
  }

  @override
  void close() {
    closes++;
    unawaited(events.close());
  }
}

void main() {
  for (final owned in [false, true]) {
    test(
        'renderer exit ${owned ? 'invokes owner cleanup' : 'leaves borrowed work running'}',
        () async {
      final provider = _Provider();
      final host = Host.start(
          HostConfig(workingDirectory: '.', providerFactory: (_) => provider));
      addTearDown(host.shutdown);
      final observer = host.connect();
      addTearDown(observer.close);
      var activeListeners = 0;
      void Function() listen() {
        activeListeners++;
        return () => activeListeners--;
      }

      final view = SessionView(
          host.connect(),
          SessionPresentation(
            theme: () => const Theme.defaults(),
            configNote: null,
            quitRequested: () => false,
            createViews: () => {},
            listenViews: (loaded, unloading) => listen(),
            listenNotices: (_) => listen(),
            listenTheme: (_) => listen(),
            settingsFor: (_) => SessionSettingsView(
                open: () async => '', repaint: () {}, close: () {}),
          ));
      final io = _Io();
      addTearDown(io.input.close);
      final screen =
          Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
      final done =
          runApp(view, screen: screen, onExit: owned ? host.shutdown : null);
      await io.listening.future.timeout(const Duration(seconds: 3));
      io.input.add('hello\r'.codeUnits);
      await provider.started.future.timeout(const Duration(seconds: 3));
      io.input.add([3]); // Ctrl-C with an empty draft exits during streaming.
      expect(await done.timeout(const Duration(seconds: 3)), 0);
      expect(activeListeners, 0);
      expect(observer.status.closed, owned);
      expect(provider.closes, owned ? 1 : 0);
      if (!owned) {
        expect(host.session.loop.running, isTrue);
        provider.events.add(const MessageComplete(
            content: [TextBlock('completed after detach')],
            stopReason: 'end_turn'));
        await provider.events.close();
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (host.session.loop.running) {
          if (DateTime.now().isAfter(deadline)) fail('turn failed to settle');
          await Future<void>.delayed(Duration.zero);
        }
        expect(host.session.lastReply, 'completed after detach');
      }
    });
  }

  test('failed frontend setup detaches and invokes cleanup exactly once',
      () async {
    final host = Host.start(HostConfig(
        workingDirectory: '.', providerFactory: (_) => ScriptedProvider([])));
    addTearDown(host.shutdown);
    final view = SessionView(
        host.connect(),
        SessionPresentation(
          theme: () => const Theme.defaults(),
          configNote: null,
          quitRequested: () => false,
          createViews: () => {},
          listenViews: (loaded, unloading) => () {},
          listenNotices: (_) => () {},
          listenTheme: (_) => () {},
          settingsFor: (_) => throw StateError('must not attach'),
        ));
    final io = _Io();
    addTearDown(io.input.close);
    final screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    late _Editor editor;
    var exits = 0;
    await expectLater(
        runApp(view,
            screen: screen,
            editorFor: (screen) => editor = _Editor(screen),
            consoleContextFor: (_, __) => throw StateError('setup failed'),
            onExit: () async {
              exits++;
            }),
        throwsStateError);
    expect(editor.closes, 1);
    expect(exits, 1);
    await expectLater(view.submit('closed'), throwsStateError);
    expect(host.session.loop.running, isFalse);
    // The injected cleanup policy did not own or close the host.
    final other = host.connect();
    other.close();
  });
}

final class _Editor extends LineEditor {
  _Editor(Screen screen) : super(screen: screen);
  int closes = 0;
  @override
  void close({bool reportLatency = true}) {
    closes++;
    super.close(reportLatency: reportLatency);
  }
}

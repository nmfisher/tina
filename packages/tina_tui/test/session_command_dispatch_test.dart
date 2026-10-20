import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart';

final class _Io implements Stdio {
  final input = StreamController<List<int>>();
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

/// A provider that keeps a turn open until the test closes its stream.
final class _PendingProvider implements LlmProvider {
  final started = Completer<void>();
  final events = StreamController<StreamEvent>();
  @override
  String get model => 'pending';
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    started.complete();
    return events.stream;
  }

  @override
  void close() {
    unawaited(events.close());
  }
}

/// A stand-in for interactive dialogs (e.g. the model picker): claims the
/// empty-argument form of the command and records that it opened.
final class _Dialog
    implements ConsoleContribution, ConsoleCommandHandler, OffersConsoleWhileRunning {
  int opened = 0;
  @override
  void attachConsole(ConsoleContext context) {}
  @override
  void repaintConsole() {}
  @override
  void detachConsole() {}
  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    if (name != 'model' || arguments.trim().isNotEmpty) return null;
    opened++;
    return Future.value();
  }
}

Future<void> _poll(Future<bool> Function() ready, {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
      'interactive dialogs open while busy; non-local commands still queue',
      () async {
    final provider = _PendingProvider();
    final host = Host.start(
        HostConfig(workingDirectory: '.', providerFactory: (_) => provider));
    addTearDown(host.shutdown);
    host.commands.publish(
        Command(name: 'model', description: '', handler: (_) async {}));
    host.commands.publish(
        Command(name: 'doit', description: '', handler: (_) async {}));

    final dialog = _Dialog();
    final view = SessionView(
        host.connect(),
        SessionPresentation(
          theme: () => const Theme.defaults(),
          configNote: null,
          quitRequested: () => false,
          createViews: () => {'dialog': dialog},
          listenViews: (loaded, unloading) => () {},
          listenTheme: (_) => () {},
          settingsFor: (_) => SessionSettingsView(
              open: () async => '', repaint: () {}, close: () {}),
        ));
    final io = _Io();
    final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24, split: false));
    final editor = LineEditor(screen: screen);
    view.attachConsole(ConsoleContext(screen: screen, editor: editor));
    addTearDown(() {
      view.close();
      editor.close(reportLatency: false);
      screen.dispose();
      unawaited(io.input.close());
    });

    // Start a turn so the session is busy.
    final turn = host.send('go');
    addTearDown(() {
      if (!provider.events.isClosed) unawaited(provider.events.close());
    });
    await provider.started.future;
    await _poll(() async => view.busy);

    // The dialog is claimed locally, so /model opens immediately.
    await view.submit('/model');
    expect(dialog.opened, 1);
    expect(view.pendingInputCount, 0);

    // Local dialog claims only the empty-argument form; an argument still
    // follows the command's running-turn policy and queues while busy.
    final argForm = view.submit('/model something');
    final other = view.submit('/doit');
    await _poll(() async => view.pendingInputCount >= 2);
    expect(dialog.opened, 1);
    expect(view.pendingInputCount, 2);

    // Finish the turn; the queued commands drain.
    provider.events.add(const MessageComplete(
        content: [TextBlock('done')], stopReason: 'end_turn'));
    await provider.events.close();
    await turn;
    await argForm.timeout(const Duration(seconds: 3));
    await other.timeout(const Duration(seconds: 3));
    expect(view.pendingInputCount, 0);
    expect(dialog.opened, 1);
  });
}

// Live probe (commit 8): drive the real ChannelPaneView + LineEditor
// headlessly against the real sqlite store, posting through the input
// line with injected keystrokes. Scratch — not part of the shipped CLI.
import 'dart:async';
import 'dart:io';

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina_channel_tui/tina_channel_tui.dart';
import 'package:tina_console/tina_console.dart';

final class _Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  int get terminalLines => 24;
  @override
  bool get hasTerminal => false;
  @override
  bool get stdinHasTerminal => false;
  @override
  bool get echoMode => false;
  @override
  bool get lineMode => false;
  @override
  void setEchoMode(bool value) {}
  @override
  void setLineMode(bool value) {}
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class _Panels implements ConsolePanels {
  @override
  Future<void> closeFocused() async {}
  @override
  List<String> describe() => [];
}

Future<void> main(List<String> args) async {
  final workspace = args.isNotEmpty ? args.first : '/tmp/pane-live-ws';
  final humanName = defaultHumanName(Platform.environment);
  print('workspace: $workspace');
  print('human identity: $humanName '
      '(TINA_HUMAN_NAME=${Platform.environment['TINA_HUMAN_NAME'] ?? '-'})');

  // Wrapped like plugin_catalog's opener (a bare top-level call lets
  // flow analysis pick the conditional export's Never variant). The
  // probe simulates one session's chat scope.
  const chatScope = 'probe-session';
  ChannelStoreApi open() => openDefaultChannelStore(workspace, chatScope);
  final store = open();
  // A stand-in agent, as a live session's channel plugin would join.
  store.setMember('#lobby', 'tacit-narwhal',
      status: 'working', role: 'main', summary: 'live pane check');

  final io = _Io();
  final screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
  final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  LineEditor.debugDoubleEscWindow = Duration.zero;
  unawaited(editor.readLine('> '));

  final view = ChannelPaneView(store, humanName: humanName);
  final attachment = ConsoleAttachment.attach(view,
      ConsoleContext(screen: screen, editor: editor).forView(
          chat: screen.chat,
          isActive: () => true,
          activate: () {},
          panels: _Panels()));

  Future<void> key(InputEvent event) async {
    editor.inject(event);
    // Injected events ride the input stream's microtasks; a few event
    // loop turns let them settle (pumpEventQueue lives in package:test).
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void show(String label) {
    print('--- pane ($label) ---');
    for (final line in view.visibleLines) {
      print('| $line');
    }
  }

  view.openPane();
  show('open, input mode: ${view.inputActive}');

  for (final chunk in ['hello from the ', 'input line @tacit-narwhal']) {
    await key(CharInput(chunk));
  }
  show('typed draft');
  print('chat editor draft untouched: "${editor.draftText}"');

  await key(ControlKey(ControlCode.enter));
  show('after Enter');

  await key(EscapeKey());
  show('after Esc #1 (input mode: ${view.inputActive})');
  await key(EscapeKey());
  print('pane open after Esc #2: ${view.isOpen}');
  await key(CharInput('back to the app - this lands in the chat draft'));
  print('chat editor draft after close: "${editor.draftText}"');

  attachment.dispose();
  editor.close(reportLatency: false);
  screen.dispose();
  await io.input.close();
  store.close();
  print('rows in store: ${open().read('#lobby').length}');}

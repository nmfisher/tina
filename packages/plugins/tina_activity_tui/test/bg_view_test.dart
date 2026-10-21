import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';

class Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();
  void feed(String value) => input.add(value.codeUnits);
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));

Map<String, Object?> bgTool(String id,
    {String name = 'bash', String command = 'sleep 5', String output = ''}) {
  return {
    'id': id,
    'name': name,
    'input': {'command': command},
    'output': output,
    'output_truncated': false,
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'progress_history': <String>[],
    'status': 'running',
  };
}

void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late BgView plugin;
  late Host host;
  late SessionConnection connection;
  late ConsoleContext context;

  setUp(() {
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    host = Host.start(HostConfig(
        workingDirectory: '.', providerFactory: (_) => ScriptedProvider([])));
    connection = host.connect();
    plugin = BgView(connection);
    context = ConsoleContext(screen: screen, editor: editor);
    plugin.attachConsole(context);
  });

  tearDown(() async {
    plugin.detachConsole();
    connection.close();
    await host.shutdown();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  test('no background processes: no status segment, browser closed', () {
    expect(context.statusSelection.hasSegments, isFalse);
    expect(plugin.isOpen, isFalse);
  });

  test('a running background process registers the status segment', () {
    expect(context.statusSelection.hasSegments, isFalse);
    plugin.applyActiveTools({'t1': bgTool('t1')});
    expect(context.statusSelection.hasSegments, isTrue);
  });

  test('F5 selects the pill and Enter opens the browser with the process', () async {
    plugin.applyActiveTools({'t1': bgTool('t1', output: 'hello from bg')});
    editor.readLine('> ');
    await tick();
    io.feed('\x1b[15~'); // F5
    await tick();
    expect(context.statusSelection.active, isTrue);
    expect(context.statusSelection.isHighlighted('tina/bg'), isTrue);

    io.feed('\r'); // Enter activates the segment
    await tick();
    expect(plugin.isOpen, isTrue);
    expect(plugin.visibleLines.join('\n'), contains('Background processes · 1 running'));
    expect(plugin.visibleLines.join('\n'), contains('bash'));
  });

  test('Enter expands live output; Esc closes the browser', () async {
    plugin.applyActiveTools({'t1': bgTool('t1', output: 'streamed line\nmore output')});
    editor.readLine('> ');
    await tick();
    io.feed('\x1b[15~'); // F5
    await tick();
    io.feed('\r'); // open browser
    await tick();
    expect(plugin.isOpen, isTrue);

    io.feed('\r'); // expand output of selected row
    await tick();
    expect(plugin.visibleLines.join('\n'), contains('streamed line'));

    io.feed('\x1b'); // Esc closes browser
    await tick();
    expect(plugin.isOpen, isFalse);
  });

  test('arrows cycle through running processes', () async {
    plugin.applyActiveTools({
      't1': bgTool('t1', command: 'first command'),
      't2': bgTool('t2', command: 'second command'),
    });
    editor.readLine('> ');
    await tick();
    io.feed('\x1b[15~'); // F5
    await tick();
    io.feed('\r'); // open browser
    await tick();
    final initial = plugin.visibleLines.join('\n');
    io.feed('\x1b[A'); // up -> move selection
    await tick();
    expect(plugin.visibleLines.join('\n'), isNot(equals(initial)));
  });
}

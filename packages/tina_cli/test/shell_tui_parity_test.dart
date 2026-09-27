// The parity guarantee: a TUI run and a shell run of the same input
// produce the same log — same host, same plugins, same services, same
// dispatch rules. Timestamps are recorded, never derived, so the
// comparison strips `at` and compares everything else entry by entry.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart'
    show ModeControl, PermissionMode;
import 'package:tina_cli/tina_cli.dart';
import 'package:tina_tui/tina_tui.dart';

/// One scripted turn: the reply text, nothing else.
ScriptedProvider scripted(String reply) =>
    ScriptedProvider([scriptedReply(reply)]);

/// Every entry as JSON with the wall-clock timestamp dropped — the one
/// field a run legitimately does not reproduce.
List<Map<String, dynamic>> comparable(List<SessionEntry> log) => [
      for (final e in log)
        (Map<String, dynamic>.of(e.toJson())..remove('at'))
    ];

void main() {
  late Directory ws;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_parity_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  test('a TUI run and a shell run produce the same log for the same input',
      () async {
    final shell = Shell.start(
      writer: SinkShellWriter(),
      providerFactory: (_) => scripted('echo reply'),
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
      ),
    );
    await shell.handle('hello');
    final shellLog = comparable(shell.host.session.loop.log);
    shell.host.close();

    final tui = TuiSession.start(
      providerFactory: (_) => scripted('echo reply'),
      workingDirectory: ws.path,
    );
    await tui.runLine('hello');
    final tuiLog = comparable(tui.host.session.loop.log);
    tui.close();

    expect(tuiLog, shellLog);
  });

  test('/mode works identically from both front ends', () async {
    final shell = Shell.start(
      writer: SinkShellWriter(),
      providerFactory: (_) => scripted('unused'),
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
      ),
    );
    await shell.handle('/mode read-only');
    final shellControl = shell.services.get<ModeControl>();
    final shellLog = comparable(shell.host.session.loop.log);
    shell.host.close();

    final tui = TuiSession.start(
      providerFactory: (_) => scripted('unused'),
      workingDirectory: ws.path,
    );
    // The TUI dispatches through the pure decision; the handler is the
    // same published command the shell ran.
    (dispatchLine(tui.commands, '/mode read-only') as RunCommand).run();
    final tuiControl = tui.services.get<ModeControl>();
    final tuiLog = comparable(tui.host.session.loop.log);
    tui.close();

    expect(tuiControl.mode, shellControl.mode);
    expect(tuiControl.mode, PermissionMode.readOnly);
    expect(tuiLog, shellLog,
        reason: 'the mode change lands as the same entry from either side');
  });

  test('an unknown /word is refused by both, and neither runs a turn',
      () async {
    final shell = Shell.start(
      writer: SinkShellWriter(),
      providerFactory: (_) => ScriptedProvider(const []),
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
      ),
    );
    await shell.handle('/nope');
    final shellLog = comparable(shell.host.session.loop.log);
    shell.host.close();

    final tui = TuiSession.start(
      providerFactory: (_) => ScriptedProvider(const []),
      workingDirectory: ws.path,
    );
    await tui.runLine('/nope');
    final tuiLog = comparable(tui.host.session.loop.log);
    tui.close();

    expect(tuiLog, shellLog, reason: 'both refuse before any turn starts');
  });
}

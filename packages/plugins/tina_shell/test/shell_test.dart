import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_shell/tina_shell.dart';
import 'package:tina_tools/tina_tools.dart';

final class CaptureTerminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) =>
      throw StateError('manual commands do not ask for approval');
}

void main() {
  late Directory root;
  late CaptureTerminal terminal;
  late ShellPlugin plugin;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-shell-');
    terminal = CaptureTerminal();
    plugin = ShellPlugin(
        terminal: terminal, workingDirectory: root.path, shell: '/bin/sh');
  });
  tearDown(() {
    plugin.closeSession();
    root.deleteSync(recursive: true);
  });

  test('command declares its prefix and cancellation without model tools', () {
    expect(plugin.commands.single.inputPrefix, '!');
    expect(plugin.commands.single.cancel, isNotNull);
    expect(plugin.commands.single.allowWhileRunning, isFalse);
    expect(plugin.tools, isEmpty);
  });
  test('empty command shows usage without launching a process', () async {
    await plugin.run('');
    expect(terminal.lines.single, contains('Usage: !command'));
  });
  test('real shell supports pipes, cwd and ordinary user write permissions',
      () async {
    final outside = Directory.systemTemp.createTempSync('tina-shell-outside-');
    addTearDown(() => outside.deleteSync(recursive: true));
    await plugin.run(
        'printf hi | cat > local; printf outside > "${outside.path}/file"; cat local');
    expect(File('${root.path}/local').readAsStringSync(), 'hi');
    expect(File('${outside.path}/file').readAsStringSync(), 'outside');
    expect(terminal.lines, contains('hi'));
    expect(terminal.lines, contains('exit code: 0'));
  }, skip: Platform.isWindows);
  test('stdout, stderr and nonzero exit are preserved as rendered lines',
      () async {
    await plugin.run('echo out; echo err >&2; exit 3');
    expect(terminal.lines, contains('out'));
    expect(terminal.lines, contains('err'));
    expect(terminal.lines, contains('exit code: 3'));
  }, skip: Platform.isWindows);
  test('output cannot emit terminal controls or flood the conversation',
      () async {
    plugin.closeSession();
    plugin = ShellPlugin(
        terminal: terminal,
        workingDirectory: root.path,
        runner: _OutputRunner('\x1b[2J\x1b[31mred\x1b[0m\x1b]0;title\x07\n' +
            List.filled(300, 'line').join('\n')));
    await plugin.run('fixture');
    final shown = terminal.lines.join('\n');
    expect(shown, contains('red'));
    expect(shown, isNot(contains('\x1b')));
    expect(shown, isNot(contains('title')));
    expect(shown, contains('shell output truncated'));
    expect(terminal.lines.length, lessThanOrEqualTo(202));
  });
  test('cancelling terminates a running shell and permits another command',
      () async {
    final pending =
        plugin.run('echo ready > started; while :; do sleep 0.05; done');
    final started = File('${root.path}/started');
    final deadline = Stopwatch()..start();
    while (!started.existsSync() &&
        deadline.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started.existsSync(), isTrue);
    plugin.commands.single.cancel!();
    await pending.timeout(const Duration(seconds: 3));
    expect(terminal.lines.join('\n'), contains('cancelled: command stopped'));
    await plugin.run('echo next');
    expect(terminal.lines, contains('next'));
  }, skip: Platform.isWindows);
  test('unloading cancels execution and suppresses late output', () async {
    plugin.closeSession();
    final runner = _PendingRunner();
    plugin = ShellPlugin(
        terminal: terminal, workingDirectory: root.path, runner: runner);
    final pending = plugin.run('fixture');
    await runner.started.future;
    plugin.closeSession();
    await pending.timeout(const Duration(seconds: 1));
    expect(terminal.lines, ['!fixture']);
  });
}

final class _OutputRunner implements ProcessRunner {
  _OutputRunner(this.output);
  final String output;
  @override
  Future<RunOutcome> run(ProcessRequest request,
          {ProcessControl? control}) async =>
      CommandCompleted(exitCode: 0, stdout: output, stderr: '');
}

final class _PendingRunner implements ProcessRunner {
  final started = Completer<void>();
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    control?.onStarted?.call();
    started.complete();
    await control!.whenCancelled;
    return const CommandCompleted(
        exitCode: -9, stdout: 'late', stderr: '', cancelled: true);
  }
}

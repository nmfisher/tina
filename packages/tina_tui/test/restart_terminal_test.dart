import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';

Future<void> main() async {
  final library = (await Isolate.resolvePackageUri(
    Uri.parse('package:tina_tui/tina_tui.dart'),
  ))!;
  final packageRoot = library.resolve('../');
  test('default backend, ANSI fallback and status preserve resumed input',
      () async {
    final result = await Process.run('python3', [
      packageRoot.resolve('../../tool/smoke_backend_selection.py').toFilePath(),
      '--dart',
      Platform.resolvedExecutable,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('default / xterm-256color: notcurses'));
    expect(result.stdout,
        contains('default / tina-nonexistent-terminal-fixture: ansi'));
    expect(result.stdout, contains('explicit notcurses failure is reported'));
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 3)));

  test('missing restart pathname does not prevent launch or resume input',
      () async {
    final result = await Process.run('python3', [
      packageRoot.resolve('../../tool/smoke_resume_terminal.py').toFilePath(),
      '--dart',
      Platform.resolvedExecutable,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('cancel (ansi)'));
    expect(result.stdout, contains('cancel (notcurses)'));
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('full restarted Tina sends input and receives a model reply', () async {
    final result = await Process.run('python3', [
      packageRoot.resolve('../../tool/smoke_restart.py').toFilePath(),
      '--dart',
      Platform.resolvedExecutable,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS full restarted app input'));
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('restart accepts terminal input after old stdin subscription closes',
      () async {
    final fixture =
        packageRoot.resolve('test/fixtures/restart_input.dart').toFilePath();
    final result = await Process.run('python3', [
      '-c',
      r'''
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], sys.argv[2]])
output = b''
deadline = time.monotonic() + 20
sent = False
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], .1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        if b'RESTART_READY' in output and not sent:
            os.write(fd, b'restarted input works\n')
            sent = True
        if b'RECEIVED:restarted input works' in output:
            _, status = os.waitpid(pid, 0)
            assert os.waitstatus_to_exitcode(status) == 0
            print('PASS')
            sys.exit(0)
    raise AssertionError(output.decode(errors='replace'))
finally:
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.close(fd)
''',
      Platform.resolvedExecutable,
      fixture
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS'));
  }, skip: Platform.isWindows);
}

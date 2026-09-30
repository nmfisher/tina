import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('restart accepts terminal input after old stdin subscription closes',
      () async {
    final fixture = File('packages/tina_tui/test/fixtures/restart_input.dart')
        .absolute
        .path;
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

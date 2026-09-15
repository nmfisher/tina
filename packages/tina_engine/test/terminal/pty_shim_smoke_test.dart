import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tina_engine/src/terminal/pty_shim_bindings.dart';
import 'package:test/test.dart';

/// Smoke test for the native shim: proves the native process boundary by
/// forking a child on a PTY and reading its output. Allocates its own PTY —
/// never touches the developer's /dev/tty, and needs no terminal on stdout.
void main() {
  test('shim ABI version is 1', () {
    expect(tina_shim_abi_version(), 1);
  });

  test('spawns /bin/sh -c "echo hi" on a PTY and reads its output', () async {
    
    final req = malloc<TinaPtySpawnRequest>();
    final out = malloc<TinaPtySpawnResult>();

    const sh = '/bin/sh';
    final shBuf = utf8.encode(sh);
    final shP = malloc<Uint8>(shBuf.length + 1);
    shP.asTypedList(shBuf.length + 1)
      ..setRange(0, shBuf.length, shBuf)
      ..[shBuf.length] = 0;

    final argC = malloc<Pointer<Uint8>>();
    final cBuf = utf8.encode('echo hi');
    final cP = malloc<Uint8>(cBuf.length + 1);
    cP.asTypedList(cBuf.length + 1)
      ..setRange(0, cBuf.length, cBuf)
      ..[cBuf.length] = 0;
    argC[0] = cP;
    argC[1] = nullptr;

    final argv = malloc<Pointer<Uint8>>(3);
    argv[0] = shP;
    argv[1] = argC[0];
    argv[2] = nullptr;

    final env = malloc<Pointer<Uint8>>();
    env[0] = nullptr;

    req.ref.executable = shP;
    req.ref.argv = argv;
    req.ref.env = env;
    req.ref.cwd = nullptr;
    req.ref.rows = 24;
    req.ref.cols = 80;

    final rc = tina_pty_spawn(req, out);
    expect(rc, 0, reason: 'spawn syscall failed');
    expect(out.ref.error, 0, reason: 'structured launch error');
    expect(out.ref.pid, greaterThan(0));
    expect(out.ref.masterFd, greaterThanOrEqualTo(0));

    // Read until the child exits, with an overall deadline.
    final buf = malloc<Uint8>(4096);
    final collected = BytesBuilder();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    int? status;
    var exited = false;
    while (!exited && DateTime.now().isBefore(deadline)) {
      final n = tina_pty_read(out.ref.masterFd, buf, 4096);
      if (n > 0) {
        collected.add(buf.asTypedList(n));
        continue;
      }
      if (n == 0) {
        // Would block (or EIO after child exit, which surfaces as -5):
        // fall through to the exit check below.
      } else if (n < 0 && n != -5) {
        fail('read error $n');
      }
      // Nothing right now: check whether the child exited.
      final st = malloc<Int32>();
      final wr = tina_pty_waitpid(out.ref.pid, st, 0);
      // ignore: avoid_print
      print('wr=' + wr.toString() + ' st=' + st.value.toString() + ' n=' + n.toString());
      if (wr > 0) {
        exited = true;
        status = st.value;
      } else if (wr == -10) {
        // ECHILD: the child already exited and was reaped earlier (the shim
        // reaps a failed exec, or a prior WNOHANG poll consumed it).
        exited = true;
      } else {
        expect(wr, 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(exited, isTrue, reason: 'child did not exit within deadline');
    expect(status == null || status & 0xff == 0, isTrue,
        reason: 'echo exited 0 (status=' + status.toString() + ')');
    expect(collected.toBytes(), containsAllInOrder([0x68, 0x69])); // "hi"

    tina_pty_close(out.ref.masterFd);
  });
}

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:tina_engine/src/terminal/pty_shim_bindings.dart';

void main() {
  test('shim ABI includes native session signalling', () {
    expect(tina_shim_abi_version(), 2);
    expect(tina_pty_signal_session(0, 0), isNegative);
    expect(tina_pty_kill(-1, 0), isNegative);
  });
  test('native spawn delivers output and the relayed exit status', () async {
    final req = calloc<TinaPtySpawnRequest>();
    final out = calloc<TinaPtySpawnResult>();
    final argv =
        buildCStringArray(['/bin/sh', '-c', 'printf hi; exit 7'], malloc);
    final env = buildCStringArray([], malloc);
    final buffer = malloc<Uint8>(4096);
    final status = calloc<Int32>();
    var spawned = false;
    try {
      req.ref
        ..executable = argv[0]
        ..argv = argv
        ..env = env
        ..rows = 24
        ..cols = 80;
      expect(tina_pty_spawn(req, out), 0);
      expect(out.ref.error, 0);
      spawned = true;
      final bytes = BytesBuilder();
      var reaped = false;
      var eof = false;
      final timer = Stopwatch()..start();
      while ((!reaped || !eof) && timer.elapsed < const Duration(seconds: 5)) {
        final n = tina_pty_read(out.ref.masterFd, buffer, 4096);
        if (n > 0) bytes.add(buffer.asTypedList(n));
        if (n < 0) eof = true;
        if (!reaped) reaped = tina_pty_reap(out.ref.statusFd, status, 0) > 0;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(reaped, isTrue);
      expect(eof, isTrue);
      expect(status.value >> 8, 7);
      expect(utf8.decode(bytes.toBytes()), 'hi');
    } finally {
      if (spawned) {
        tina_pty_signal_session(out.ref.pid, 9);
        tina_pty_close(out.ref.masterFd);
        tina_pty_close(out.ref.statusFd);
      }
      freeCStringArray(argv, malloc);
      freeCStringArray(env, malloc);
      malloc.free(buffer);
      calloc.free(status);
      calloc.free(req);
      calloc.free(out);
    }
  });
}

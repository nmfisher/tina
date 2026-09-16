// Low-level FFI binding to the tina PTY shim.
//
// Loaded as a native asset (see hook/build.dart), not with
// DynamicLibrary.open. The Dart-side wrapper is PtyRunner in
// pty_runner.dart; this file is just the raw externals and structs.
//
// The exec-error channel: on a structured launch failure the shim reports the
// child's errno in TinaPtySpawnResult.error and leaves pid/masterFd at -1.
import 'dart:convert';
import 'dart:ffi';

const String _asset = 'package:tina_engine/src/terminal/pty_shim.dart';

@Native<Int32 Function()>(assetId: _asset)
external int tina_shim_abi_version();

final class TinaPtySpawnRequest extends Struct {
  external Pointer<Uint8> executable;
  external Pointer<Pointer<Uint8>> argv;
  external Pointer<Pointer<Uint8>> env;
  external Pointer<Uint8> cwd;
  @Int32()
  external int rows;
  @Int32()
  external int cols;
}

final class TinaPtySpawnResult extends Struct {
  @Int32()
  external int pid;
  @Int32()
  external int masterFd;
  @Int32()
  external int statusFd;
  @Int32()
  external int error;
}

/// Returns 0 when the call itself succeeded — check [TinaPtySpawnResult.error]
/// for a structured launch failure (child-side errno). Negative return means
/// the shim failed before fork (that errno).
@Native<
    Int32 Function(Pointer<TinaPtySpawnRequest>,
        Pointer<TinaPtySpawnResult>)>(assetId: _asset)
external int tina_pty_spawn(
    Pointer<TinaPtySpawnRequest> req, Pointer<TinaPtySpawnResult> out);

/// Bytes read, 0 = would block, negative = -errno.
@Native<Int32 Function(Int32, Pointer<Uint8>, Int32)>(assetId: _asset)
external int tina_pty_read(int fd, Pointer<Uint8> buf, int len);

/// Bytes written (may be short), 0 = would block, negative = -errno.
@Native<Int32 Function(Int32, Pointer<Uint8>, Int32)>(assetId: _asset)
external int tina_pty_write(int fd, Pointer<Uint8> buf, int len);

/// 0 or -errno.
@Native<Int32 Function(Int32)>(assetId: _asset)
external int tina_pty_close(int fd);

/// 0 or -errno.
@Native<Int32 Function(Int32, Int32, Int32)>(assetId: _asset)
external int tina_pty_resize(int fd, int rows, int cols);

/// 0 or -errno.
@Native<Int32 Function(Int32, Int32)>(assetId: _asset)
external int tina_pty_kill(int pid, int sig);

/// Live session members signalled (zero only probes), or negative errno.
@Native<Int32 Function(Int32, Int32)>(assetId: _asset)
external int tina_pty_signal_session(int sid, int sig);

/// pid on exit, 0 = still running, negative = -errno. Only used on the
/// spawn-failure path to reap the supervisor.
@Native<Int32 Function(Int32, Pointer<Int32>, Int32)>(assetId: _asset)
external int tina_pty_waitpid(int pid, Pointer<Int32> status, int waitForExit);

/// Read the child's exit status relayed over the spawn's status pipe.
/// > 0 with [status] set on exit, 0 = still running, negative = -errno.
@Native<Int32 Function(Int32, Pointer<Int32>, Int32)>(assetId: _asset)
external int tina_pty_reap(
    int statusFd, Pointer<Int32> status, int waitForExit);

/// 1 = readable/EOF, 0 = timeout, negative = -errno.
@Native<Int32 Function(Int32, Int32)>(assetId: _asset)
external int tina_pty_poll(int fd, int timeoutMs);

// ---------------------------------------------------------------------------
// Allocation helpers (used by PtyRunner; materialize everything BEFORE the
// shim's fork, never inside it).
// ---------------------------------------------------------------------------

/// Builds a NUL-terminated argv/envp array from [items]. Caller frees the
/// result and every element via [freeCStringArray].
Pointer<Pointer<Uint8>> buildCStringArray(List<String> items, Allocator alloc) {
  final arr = alloc<Pointer<Uint8>>(items.length + 1);
  for (var i = 0; i < items.length; i++) {
    final unit8 = const Utf8Encoder().convert(items[i]);
    final p = alloc<Uint8>(unit8.length + 1);
    arr[i] = p;
    p.asTypedList(unit8.length + 1)
      ..setRange(0, unit8.length, unit8)
      ..[unit8.length] = 0;
  }
  arr[items.length] = nullptr;
  return arr;
}

void freeCStringArray(Pointer<Pointer<Uint8>> arr, Allocator alloc) {
  var i = 0;
  while (arr[i] != nullptr) {
    alloc.free(arr[i]);
    i++;
  }
  alloc.free(arr);
}

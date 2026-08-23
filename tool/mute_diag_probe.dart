// Diagnostic replica of the mute-terminal init path (TINA_IMPROVEMENTS_LOG #33).
//
// Runs exactly the stages of NotcursesBackend.create()'s reply-guard flow,
// reporting at each boundary:
//   - fd 0's termios flag summary (ICANON/ECHO/ISIG/ICRNL/OPOST, VMIN/VTIME)
//   - the /proc/self/fd target of notcurses' input-ready descriptor
//   - guard state (armed / bridge running) and the pump's record count
//
// Companion: tool/syscall_diag_driver.py (stays mute, injects keys, and
// snapshots fds/syscalls/FIONREAD from outside the whole run).
// Usage: dart run tool/mute_diag_probe.dart [probeLog] [diagLog]
import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:tina_console/src/backend/init_reply_guard.dart';

// -- minimal FFI: tcgetattr for the diagnostics ------------------------------

const int _nccs = 32; // linux
const int _offIflag = 0;
const int _offLflag = 12;
const int _offCc = 17; // after 4 tcflag_t + c_line
const int _vtime = 5;
const int _vmin = 6;

const int _isig = 0x1;
const int _icanon = 0x2;
const int _echo = 0x8;
const int _icrnl = 0x100;

final ffi.DynamicLibrary _libc = ffi.DynamicLibrary.process();
final _tcgetattr = _libc.lookupFunction<
    ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>),
    int Function(int, ffi.Pointer<ffi.Uint8>)>('tcgetattr');
final _poll = _libc.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Uint64, ffi.Int32),
    int Function(ffi.Pointer<ffi.Uint8>, int, int)>('poll');
final _readFn = _libc.lookupFunction<
    ffi.Int64 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Int64),
    int Function(int, ffi.Pointer<ffi.Uint8>, int)>('read');

/// poll(fd0, POLLIN, 0) — is there anything to read right now? Returns
/// 'R' (readable), '.' (idle) or 'E' (poll errored).
String fd0Readable() {
  final p = _mallocFn(8).cast<ffi.Uint8>();
  try {
    p.cast<ffi.Int32>()[0] = 0;
    p.cast<ffi.Int16>()[2] = 0x0001; // POLLIN at byte offset 4
    final rc = _poll(p, 1, 0);
    if (rc < 0) return 'E';
    return rc > 0 ? 'R' : '.';
  } finally {
    _freeFn(p.cast());
  }
}

/// Non-blocking peek at fd 0 WITHOUT consuming: poll first, then read only
/// when readable. Bytes read are logged (and lost — diagnosis only).
int fd0DrainPeek() {
  if (fd0Readable() != 'R') return 0;
  final buf = _mallocFn(256).cast<ffi.Uint8>();
  try {
    final n = _readFn(0, buf, 256);
    if (n <= 0) return n == 0 ? 0 : -1;
    final hex = [
      for (var i = 0; i < n; i++) buf[i].toRadixString(16)
    ].join(' ');
    // ignore: avoid_print
    stderr.writeln('FD0PEEK read $n bytes: $hex');
    return n;
  } finally {
    _freeFn(buf.cast());
  }
}
final _mallocFn = _libc.lookupFunction<
    ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
    ffi.Pointer<ffi.Void> Function(int)>('malloc');
final _freeFn = _libc.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
    void Function(ffi.Pointer<ffi.Void>)>('free');
final _openFn = _libc.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Int32),
    int Function(ffi.Pointer<ffi.Uint8>, int)>('open');
final _writeFn = _libc.lookupFunction<
    ffi.Int64 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Int64),
    int Function(int, ffi.Pointer<ffi.Uint8>, int)>('write');
final _tcsetattr = _libc.lookupFunction<
    ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>),
    int Function(int, int, ffi.Pointer<ffi.Uint8>)>('tcsetattr');
final _cfmakerawFn = _libc.lookupFunction<
    ffi.Void Function(ffi.Pointer<ffi.Uint8>),
    void Function(ffi.Pointer<ffi.Uint8>)>('cfmakeraw');

/// One-line summary of fd 0's line discipline state.
String termiosSummary() {
  try {
    final buf = _mallocFn(_nccs + 32).cast<ffi.Uint8>();
    try {
      if (_tcgetattr(0, buf) != 0) return 'tcgetattr(failed)';
      final ints = buf.cast<ffi.Int32>();
      final iflag = ints[_offIflag ~/ 4];
      final lflag = ints[_offLflag ~/ 4];
      final vtime = buf[_offCc + _vtime];
      final vmin = buf[_offCc + _vmin];
      String flag(bool set, String name) => set ? name : '-';
      return 'ICANON=${flag((lflag & _icanon) != 0, 'Y')}'
          ' ECHO=${flag((lflag & _echo) != 0, 'Y')}'
          ' ISIG=${flag((lflag & _isig) != 0, 'Y')}'
          ' ICRNL=${flag((iflag & _icrnl) != 0, 'Y')}'
          ' VMIN=$vmin VTIME=$vtime';
    } finally {
      _freeFn(buf.cast());
    }
  } catch (e) {
    return 'err:$e';
  }
}

Future<void> main(List<String> args) async {
  final logPath =
      args.isNotEmpty ? args.first : '/tmp/mute_diag/probe.log';
  final diagPath = args.length > 1 ? args[1] : '/tmp/mute_diag/diag.log';
  // --nopump: diagnostic mode that never starts the input pump, so nothing
  // of ours drains notcurses' queue or its ready pipe. The heartbeat then
  // polls fd 0, the mystery duplicate-tty fd (e.g. 13 -> same pts as fd 0)
  // and notcurses' readyfd directly, and dequeues via getNonBlocking.
  final nopump = args.contains('--nopump');
  // --nobridge: stop the stdin bridge immediately after restore(). If the
  // keyboard comes alive only without it, the bridge itself is the consumer
  // starving notcurses' real input fd.
  final nobridge = args.contains('--nobridge');
  final log = File(logPath).openSync(mode: FileMode.writeOnly);
  final diag = File(diagPath).openSync(mode: FileMode.writeOnly);
  var records = 0;
  void logLine(String s) =>
      log.writeStringSync('${DateTime.now().millisecondsSinceEpoch} $s\n');
  void diagLine(String s) =>
      diag.writeStringSync('${DateTime.now().millisecondsSinceEpoch} $s\n');

  // Own OS handle so the probe can reach bridgeMasterFd for the MASTERFEED
  // experiment (#33): inject a marker byte into the detour master and see
  // whether it surfaces as a pump record (isolates the pump->Dart path from
  // the fd-0 delivery path).
  final guardOs = ReplyGuardOs.posix();
  String fd0Target() {
    try {
      return Link('/proc/self/fd/0').targetSync();
    } catch (_) {
      return 'err';
    }
  }

  String readyFdTarget(nc.NotCurses ncs) {
    try {
      final fd = ncs.getInputReadyFD();
      final target = Link('/proc/self/fd/$fd').targetSync();
      return '$fd -> $target';
    } catch (e) {
      return 'unresolved($e)';
    }
  }

  /// Compact /proc/self/fd map (readlink works where realpath fails).
  String fdMap() {
    try {
      final out = <String>[];
      for (final e in Directory('/proc/self/fd').listSync()) {
        final n = int.tryParse(e.path.split('/').last);
        if (n == null) continue;
        try {
          out.add('$n:${Link(e.path).targetSync()}');
        } catch (_) {}
      }
      out.sort();
      return out.join(' ');
    } catch (_) {
      return 'err';
    }
  }

  /// fds other than 0/1/2 that refer to the SAME tty device as fd 0 — the
  /// mystery duplicate an input thread could be polling instead of fd 0.
  List<int> duplicateTtyFds() {
    final t = fd0Target();
    if (t == 'err') return const [];
    final out = <int>[];
    try {
      for (final e in Directory('/proc/self/fd').listSync()) {
        final n = int.tryParse(e.path.split('/').last);
        if (n == null || n <= 2) continue;
        try {
          if (Link(e.path).targetSync() == t) out.add(n);
        } catch (_) {}
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  String fdInfoFlags(int fd) {
    try {
      for (final line in File('/proc/self/fdinfo/$fd').readAsLinesSync()) {
        if (line.startsWith('flags:')) return line.trim();
      }
    } catch (_) {}
    return 'flags:?';
  }

  String fdReadableChar(int fd) {
    final p = _mallocFn(8).cast<ffi.Uint8>();
    try {
      p.cast<ffi.Int32>()[0] = fd;
      p.cast<ffi.Int16>()[2] = 0x0001;
      final rc = _poll(p, 1, 0);
      if (rc < 0) return 'E';
      return rc > 0 ? 'R' : '.';
    } finally {
      _freeFn(p.cast());
    }
  }

  diagLine('A boot: ${termiosSummary()} fd0t=${fd0Target()} | ${fdMap()}');
  final guard = TerminalReplyGuard(os: guardOs)..prepare();
  diagLine('B prepared: armed=${guard.armed} | ${termiosSummary()} | '
      '${fdMap()}');

  // --keepdetour: leave fd 0 on the detour pty for the whole session and
  // bridge the REAL tty (opened by name from fd 1's target, exactly as
  // notcurses itself does) into the detour master. notcurses' input thread
  // entered ppoll(fd 0) during init and bound the DETOUR slave, so poll and
  // read only agree if fd 0 never moves again.
  final keepdetour = args.contains('--keepdetour');

  nc.NotCurses ncs;
  try {
    ncs = nc.NotCurses(nc.CursesOptions(
      loglevel: nc.LogLevel.silent,
      flags: nc.OptionFlags.suppressBanners,
    ));
  } finally {
    if (!keepdetour) guard.finishInit();
  }
  if (ncs.notInitialized) {
    stderr.writeln('notcurses init failed');
    exit(1);
  }

  if (keepdetour) {
    final master = guardOs.bridgeMasterFd;
    final realPath = Link('/proc/self/fd/1').targetSync();
    final p = _mallocFn(realPath.length + 1).cast<ffi.Uint8>();
    for (var i = 0; i < realPath.length; i++) {
      p[i] = realPath.codeUnitAt(i);
    }
    p[realPath.length] = 0;
    final realFd = _openFn(p, 0x902); // O_RDWR|O_NOCTTY|O_NONBLOCK
    _freeFn(p.cast());
    final tio = _mallocFn(128).cast<ffi.Uint8>();
    if (realFd >= 0 && _tcgetattr(realFd, tio) == 0) {
      _cfmakerawFn(tio);
      _tcsetattr(realFd, 0, tio);
    }
    _freeFn(tio.cast());
    diagLine('K keepdetour: realFd=$realFd ($realPath) master=$master '
        'fd0t=${fd0Target()}');
    Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (realFd < 0 || master < 0) return;
      final buf = _mallocFn(4096);
      try {
        final n = _readFn(realFd, buf.cast<ffi.Uint8>(), 4096);
        if (n > 0) {
          final hex = [
            for (var i = 0; i < n; i++) buf.cast<ffi.Uint8>()[i]
                .toRadixString(16)
          ].join(' ');
          stderr.writeln('BRIDGE2 moved $n: $hex');
          var off = 0;
          while (off < n) {
            final w = _writeFn(master, buf.cast<ffi.Uint8>() + off, n - off);
            if (w <= 0) break;
            off += w;
          }
        }
      } finally {
        _freeFn(buf);
      }
    });
  }

  // (bridgeRunning is @visibleForTesting, so a tool cannot read it; the fd
  // map below shows the bridge's handiwork — saved real stdin + master —
  // and the heartbeat shows bytes moving.)
  diagLine(
      'C post-init+restore: '
      'readyFd=${readyFdTarget(ncs)} fd0t=${fd0Target()} | '
      '${termiosSummary()}');
  final dupsAtC = duplicateTtyFds();
  diagLine('C2 dup-tty-fds=${dupsAtC.isEmpty ? "none" : dupsAtC.join(",")} '
      '(${dupsAtC.map(fdInfoFlags).join(' | ')})');

  if (nobridge) {
    guard.shutdown();
    diagLine('D0 bridge DISABLED by --nobridge; nothing copies fd 0 anymore');
  }

  final plane = ncs.stdplane();
  plane.putStrYX(0, 0, 'MUTE-DIAG probe — driver injects keys next.');
  plane.putStrYX(1, 0, 'records log to: $logPath   diag: $diagPath');
  ncs.render();
  diagLine('D rendered | ${termiosSummary()} | ${fdMap()}');

  if (nopump) {
    // Pump-free observation loop: nothing of ours touches notcurses' queue
    // or ready pipe, so readability of the readyfd is ground truth for
    // "notcurses' own input machinery produced an event".
    final readyFd = ncs.getInputReadyFD();
    var quitSeen = false;
    var beats = 0;
    final dups = duplicateTtyFds();
    late final Timer hb;
    hb = Timer.periodic(const Duration(milliseconds: 100), (_) {
      beats++;
      final dupState = dups
          .map((f) => '$f=${fdReadableChar(f)}')
          .join(' ');
      final direct = ncs.getNonBlocking();
      final directId = direct.value?.id;
      if (direct.value != null) direct.value!.destroy();
      diagLine('nopump beat#$beats: fd0=${fdReadableChar(0)} '
          'ready($readyFd)=${fdReadableChar(readyFd)} '
          'dup[$dupState] direct=0x${(directId ?? 0).toRadixString(16)}');
      if (directId == 0x71 && !quitSeen) {
        quitSeen = true;
        diagLine('G quit-key seen DIRECTLY');
        Timer(const Duration(milliseconds: 100), () {
          hb.cancel();
          log.close();
          diag.close();
          ncs.stop();
          exit(0);
        });
      }
    });
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    diagLine('H timeout');
    hb.cancel();
    log.close();
    diag.close();
    ncs.stop();
    exit(0);
  }

  final pump = ncs.startInputPump();
  var spinGarbage = 0;
  late final StreamSubscription sub;
  sub = pump.events.listen((rec) {
    records++;
    final id = rec.id;
    final mods = rec.modifiers;
    // Guard against the pump spinning on a non-tty fd (garbage record ids):
    // cap the log so a pathological fd cannot balloon it again.
    if (id > 0x110000 || (id < 0x20 && id != 0x03 && id != 0x1b)) {
      spinGarbage++;
      if (spinGarbage <= 5) {
        logLine('pump: GARBAGE id=0x${id.toRadixString(16)} mods=$mods');
      }
      return;
    }
    final name = id >= 0x20 && id < 0x7f
        ? "'${String.fromCharCode(id)}'"
        : '0x${id.toRadixString(16)}';
    logLine('pump: $name id=0x${id.toRadixString(16)} mods=$mods');
    if (id == 0x71 && mods == 0) {
      Timer(const Duration(milliseconds: 50), () async {
        diagLine('G quit-key seen: records=$records');
        await sub.cancel();
        pump.stop();
        log.close();
        diag.close();
        ncs.stop();
        exit(0);
      });
    }
  });

  // Heartbeat: termios + counters every 500ms so the driver-side timeline
  // shows exactly when (and whether) the line discipline changes under us.
  var beats = 0;
  final hb = Timer.periodic(const Duration(milliseconds: 500), (_) {
    beats++;
    diagLine('beat#$beats: records=$records spinGarbage=$spinGarbage '
        'fd0=${fd0Readable()} fd0t=${fd0Target()} | ${termiosSummary()}');
    // MASTERFEED: push 'x' (0x78) straight into the detour master, the pty
    // notcurses allegedly still decodes from. If records jumps afterwards,
    // everything from the detour slave through notcurses' queue through the
    // pump's ring and the Dart notify is ALIVE, and the break is purely in
    // real-stdin -> master delivery.
    if (beats == 3 || beats == 13) {
      final m = guardOs.bridgeMasterFd;
      if (m >= 0) {
        final n = guardOs.writeBytes(m, Uint8List.fromList([0x78]));
        diagLine('MASTERFEED sent n=$n records=$records');
      } else {
        diagLine('MASTERFEED no master');
      }
    }
    // Direct dequeue from notcurses, bypassing the pump entirely: if the
    // injected keys are sitting in notcurses' internal queue, the input
    // pipeline up to notcurses is ALIVE and the break is pump->Dart.
    try {
      final direct = ncs.getNonBlocking();
      if (direct.value != null && direct.result != 0) {
        // ignore: avoid_print
        stderr.writeln('DIRECTGET id=0x'
            '${direct.value!.id.toRadixString(16)}');
        direct.value!.destroy();
      }
    } catch (_) {}
    fd0DrainPeek();
  });

  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  diagLine('H timeout: records=$records');
  hb.cancel();
  await sub.cancel();
  pump.stop();
  log.close();
  diag.close();
  ncs.stop();
  exit(0);
}

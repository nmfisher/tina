import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tina_console/src/backend/init_reply_guard.dart';

/// Recording fake for [ReplyGuardOs]: every call is appended to [calls] as a
/// short string, so tests assert on the choreography rather than on real fds.
class FakeReplyGuardOs implements ReplyGuardOs {
  FakeReplyGuardOs({
    this.terminals = const {0: true, 1: true},
    this.replyArrives = false,
    this.rawModeOk = true,
    this.detourOk = true,
    this.masterOnDetour = true,
  });

  /// fd → is a terminal. Defaults to both stdio being terminals.
  final Map<int, bool> terminals;

  /// Whether the probe reply shows up within the timeout.
  final bool replyArrives;

  /// Whether [enterRawMode] can capture and change the mode.
  final bool rawModeOk;

  /// Whether [installDetour] succeeds.
  final bool detourOk;

  /// Whether a successful [installDetour] leaves a pty master behind, as
  /// the POSIX implementation does for the stdin bridge.
  final bool masterOnDetour;

  /// The detour pty master fd handed to the bridge; −1 when there is none.
  int masterFd = -1;

  /// The real-stdin fd the bridge reads; −1 until a session begins, and
  /// again after it ends (mirrors the POSIX lifecycle).
  int sourceFd = -1;
  final calls = <String>[];
  String? detourReply;

  /// Set when [abandon] runs — the guard must release a half-installed
  /// detour without touching fd 0.
  bool abandoned = false;

  @override
  bool isTerminal(int fd) {
    calls.add('isatty($fd)');
    return terminals[fd] ?? false;
  }

  @override
  void write(int fd, String bytes) => calls.add('write($fd,${bytes.length})');

  @override
  bool pollReadable(int fd, int timeoutMs) {
    calls.add('poll($fd,$timeoutMs)');
    return replyArrives;
  }

  @override
  void drain(int fd, int maxBytes) => calls.add('drain($fd,$maxBytes)');

  @override
  Object? enterRawMode(int fd) {
    calls.add('raw($fd)');
    return rawModeOk ? 'saved-mode' : null;
  }

  @override
  void restoreMode(int fd, Object? saved) =>
      calls.add('unraw($fd,${saved == null ? 'null' : 'saved'})');

  @override
  bool installDetour(String reply) {
    calls.add('detour(${reply.length})');
    detourReply = reply;
    if (detourOk && masterOnDetour) {
      masterFd = 42;
      sourceFd = 7;
    }
    return detourOk;
  }

  @override
  void beginBridgedSession() {
    calls.add('beginBridgedSession()');
    if (sourceFd < 0 && masterFd >= 0) sourceFd = 7;
  }

  @override
  void endBridgedSession() {
    calls.add('endBridgedSession()');
    sourceFd = -1;
    releaseBridgeMaster();
  }

  @override
  int get bridgeSourceFd => sourceFd;

  @override
  int get bridgeMasterFd => masterFd;

  @override
  void releaseBridgeMaster() {
    calls.add('releaseBridgeMaster()');
    masterFd = -1;
  }

  @override
  Uint8List readBytes(int fd, int maxBytes) {
    calls.add('readBytes($fd,$maxBytes)');
    return Uint8List(0); // no data available by default
  }

  @override
  int writeBytes(int fd, Uint8List bytes) {
    calls.add('writeBytes($fd,${bytes.length})');
    return bytes.length; // best-effort: accepts everything
  }

  @override
  void abandon() {
    calls.add('abandon()');
    abandoned = true;
  }
}

void main() {
  group('TerminalReplyGuard (tin-r2vd)', () {
    test('mute terminal: probes, then detours fd 0 with a fallback DA1', () {
      final os = FakeReplyGuardOs(replyArrives: false);
      final guard = TerminalReplyGuard(os: os);

      final armed = guard.prepare();

      expect(armed, isTrue, reason: 'a mute terminal must arm the detour');
      expect(guard.armed, isTrue);
      // The probe runs with echo off, and the mode comes back before the
      // detour is installed.
      expect(os.calls, containsAllInOrder(<String>[
        'isatty(0)',
        'isatty(1)',
        'raw(0)',
        'write(1,${TerminalReplyGuard.probeQuery.length})', // OSC 10 + OSC 11
        'poll(0,${TerminalReplyGuard.probeTimeoutMs})',
        'unraw(0,saved)',
        'detour(${TerminalReplyGuard.fallbackReply.length})',
      ]));
      // The reply handed to the pty must be a DA1 — that is the only reply
      // notcurses' init wait will accept (see inputlayer_get_responses).
      expect(os.detourReply, startsWith('\x1b[?'));
      expect(os.detourReply, endsWith('c'));

      guard.finishInit();
      expect(os.calls.last, 'beginBridgedSession()');
      expect(guard.armed, isFalse, reason: 'finishInit disarms the guard');
    });

    test('answering terminal: stands down and consumes the probe reply', () {
      final os = FakeReplyGuardOs(replyArrives: true);
      final guard = TerminalReplyGuard(os: os);

      expect(guard.prepare(), isFalse);
      expect(guard.armed, isFalse);
      expect(os.calls, containsAllInOrder(
          ['raw(0)', 'write(1,${TerminalReplyGuard.probeQuery.length})', 'poll(0,${TerminalReplyGuard.probeTimeoutMs})', 'drain(0,4096)', 'unraw(0,saved)']));
      // Nothing may touch fd 0's identity on the normal path.
      expect(os.calls.any((c) => c.startsWith('detour')), isFalse);
      expect(os.calls.any((c) => c == 'beginBridgedSession()'), isFalse);
    });

    test('answering terminal: finishInit() is a no-op', () {
      final os = FakeReplyGuardOs(replyArrives: true);
      final guard = TerminalReplyGuard(os: os)..prepare();
      guard.finishInit();
      expect(os.calls.any((c) => c == 'beginBridgedSession()'), isFalse);
    });

    test('no terminal on stdio: does not probe at all', () {
      final os = FakeReplyGuardOs(terminals: {0: false, 1: true});
      expect(TerminalReplyGuard(os: os).prepare(), isFalse);
      expect(os.calls, ['isatty(0)']);
    });

    test('raw mode unavailable: skips the probe rather than echoing garbage',
        () {
      final os = FakeReplyGuardOs(rawModeOk: false);
      expect(TerminalReplyGuard(os: os).prepare(), isFalse);
      expect(os.calls, ['isatty(0)', 'isatty(1)', 'raw(0)', 'unraw(0,null)']);
      expect(os.calls.any((c) => c.startsWith('write')), isFalse,
          reason: 'a query whose reply would be echoed must not be sent');
    });

    test('detour unavailable: stands down without arming', () {
      final os = FakeReplyGuardOs(detourOk: false);
      final guard = TerminalReplyGuard(os: os);
      expect(guard.prepare(), isFalse);
      expect(guard.armed, isFalse);
      guard.finishInit();
      expect(os.calls.any((c) => c == 'beginBridgedSession()'), isFalse);
    });

    test('a throw from the os layer never escapes prepare', () {
      final os = _ThrowingOs();
      final guard = TerminalReplyGuard(os: os);
      expect(guard.prepare(), isFalse);
      expect(guard.armed, isFalse);
      expect(os.abandoned, isTrue,
          reason: 'a half-installed detour must be released');
    });

    test('probe timeout is bounded', () {
      // The whole point of the fix: the wait must be finite.
      expect(TerminalReplyGuard.probeTimeoutMs, inInclusiveRange(1, 5000));
    });

    test('default construction: guard and bridge share one os layer', () {
      // The bridge moves bytes between the fds the detour opened. A second
      // os instance (master/source forever −1) turns the copy loop into a
      // silent no-op — exactly the regression that kept the keyboard dead
      // after the keep-detour fix: every unit test passed (they inject one
      // shared os) while TerminalReplyGuard() in production moved nothing.
      expect(TerminalReplyGuard().sharesOsLayer, isTrue);
    });
  });

  group('StdinBridge (tin-DEAD-KEYBOARD)', () {
    test('copy loop: stdin bytes reach the master, nothing buffered', () {
      final os = _BridgeFakeOs(stdinQueue: [utf8Bytes('ab'), utf8Bytes('cd')]);
      final bridge = StdinBridge(os);

      bridge.tick();

      // One writeBytes call per stdin chunk; the master sees the same bytes
      // in order either way.
      expect(os.writtenToMaster.join(), 'abcd');
      expect(bridge.pendingBytes, 0);
    });

    test('tick with no stdin data is a no-op', () {
      final os = _BridgeFakeOs();
      final bridge = StdinBridge(os);

      bridge.tick();

      expect(os.writtenToMaster, isEmpty);
      expect(os.calls.where((c) => c.startsWith('writeBytes')), isEmpty);
    });

    test('short write: remainder is buffered and retried next tick', () {
      final os = _BridgeFakeOs(
          stdinQueue: [utf8Bytes('hello')], writeBudget: 3);
      final bridge = StdinBridge(os);

      bridge.tick();
      // 'hel' accepted, 'lo' parked.
      expect(os.writtenToMaster, ['hel']);
      expect(bridge.pendingBytes, 2);

      // Next tick flushes the remainder before reading fresh input.
      os.writeBudget = 99;
      bridge.tick();
      expect(os.writtenToMaster, ['hel', 'lo']);
      expect(bridge.pendingBytes, 0);
    });

    test('write failure (EAGAIN): everything is buffered, nothing lost', () {
      final os = _BridgeFakeOs(stdinQueue: [utf8Bytes('xyz')], writeBudget: 0);
      final bridge = StdinBridge(os);

      bridge.tick();
      expect(os.writtenToMaster, isEmpty);
      expect(bridge.pendingBytes, 3);

      os.writeBudget = 99;
      bridge.tick();
      expect(os.writtenToMaster, ['xyz']);
    });

    test('buffer is bounded: overflow drops the OLDEST bytes', () {
      final os = _BridgeFakeOs(writeBudget: 0);
      final bridge = StdinBridge(os);

      // Push far more than the 256 KiB drop limit through feedBytes.
      final big = Uint8List.fromList(
          List.generate(_BridgeFakeOs.overflowProbeBytes, (i) => i & 0x7f));
      bridge.feedBytes(big);
      expect(bridge.pendingBytes, StdinBridge.pendingDropLimit);

      // The survivors must be the tail of what was fed (oldest dropped).
      // Budget covers the whole survivor tail so the flush drains it all.
      os.writeBudget = StdinBridge.pendingDropLimit;
      bridge.tick();
      final delivered = os.writtenToMaster
          .expand<int>((b) => b.codeUnits)
          .toList();
      expect(delivered.length, StdinBridge.pendingDropLimit);
      expect(
          delivered,
          big.sublist(
              big.length - StdinBridge.pendingDropLimit));
    });

    test('tick caps work per wake-up (firehose cannot starve the loop)', () {
      final os = _BridgeFakeOs(
          stdinQueue: List.generate(50, (_) => Uint8List(_BridgeFakeOs.chunkSize)),
          writeBudget: 99);
      final bridge = StdinBridge(os);

      bridge.tick();

      expect(os.calls.where((c) => c.startsWith('readBytes')).length,
          StdinBridge.maxChunksPerTick);
      // The rest stays queued for later ticks.
      expect(os.stdinQueue.length, 50 - StdinBridge.maxChunksPerTick);
    });

    test('read error: tick swallows, loop keeps going', () {
      final os = _BridgeFakeOs(throwOnRead: true);
      final bridge = StdinBridge(os);

      expect(() => bridge.tick(), returnsNormally);
      expect(os.calls.where((c) => c.startsWith('writeBytes')), isEmpty,
          reason: 'nothing was read, so nothing was written');
      // A later tick still runs.
      expect(() => bridge.tick(), returnsNormally);
    });

    test('write error: tick swallows, loop keeps going', () {
      final os = _BridgeFakeOs(throwOnWrite: true);
      final bridge = StdinBridge(os);

      expect(() => bridge.tick(), returnsNormally);
      expect(() => bridge.tick(), returnsNormally);
    });

    test('released master: tick does nothing (no reads, no writes)', () {
      final os = _BridgeFakeOs(stdinQueue: [utf8Bytes('q')]);
      final bridge = StdinBridge(os);
      os.masterFd = -1; // releaseBridgeMaster already ran

      bridge.tick();

      expect(os.calls.where((c) => c.startsWith('readBytes')), isEmpty);
    });

    test('ended session (no source fd): tick does not lift bytes', () {
      final os = _BridgeFakeOs(stdinQueue: [utf8Bytes('q')]);
      final bridge = StdinBridge(os);
      os.sourceFd = -1; // endBridgedSession already ran

      bridge.tick();

      expect(os.calls.where((c) => c.startsWith('readBytes')), isEmpty,
          reason: 'the real stdin is closed; reading fd 0 now would steal '
              'bytes from the detour notcurses is wedged to');
    });

    test('start/stop lifecycle: timer arms, cancels, restartable', () {
      final os = _BridgeFakeOs();
      final bridge = StdinBridge(os);

      expect(bridge.running, isFalse);
      bridge.start();
      expect(bridge.running, isTrue);
      bridge.start(); // idempotent
      expect(bridge.running, isTrue);
      bridge.stop();
      expect(bridge.running, isFalse);
      bridge.stop(); // idempotent
      expect(bridge.running, isFalse);
      bridge.start();
      expect(bridge.running, isTrue);
    });

    test('stop drops undelivered buffered bytes (keyboard is going away)', () {
      final os = _BridgeFakeOs(writeBudget: 0);
      final bridge = StdinBridge(os);
      bridge.feedBytes(utf8Bytes('abc'));
      expect(bufferedCount(bridge), 3);

      bridge.stop();
      expect(bufferedCount(bridge), 0);
    });

    test('tick cadence is fast enough to be imperceptible', () {
      // A keypress must wait at most one tick; anything above ~50 ms would
      // feel laggy against a human typing cadence.
      expect(StdinBridge.tickMs, inInclusiveRange(1, 50));
    });
  });

  group('TerminalReplyGuard bridge lifecycle (tin-DEAD-KEYBOARD)', () {
    test('mute path: finishInit() starts the bridge, shutdown() ends it',
        () {
      final os = FakeReplyGuardOs(replyArrives: false);
      final guard = TerminalReplyGuard(os: os)..prepare();
      addTearDown(guard.shutdown);

      expect(guard.armed, isTrue);
      expect(guard.bridgeRunning, isFalse,
          reason: 'the bridge only starts once init has returned');
      guard.finishInit();
      expect(guard.bridgeRunning, isTrue,
          reason: 'notcurses reads the detour pty for the whole session; '
              'the real stdin must be bridged into it or the keyboard '
              'dies');

      guard.shutdown();
      expect(guard.bridgeRunning, isFalse);
      guard.shutdown(); // idempotent
      expect(guard.bridgeRunning, isFalse);
      expect(os.calls.where((c) => c.startsWith('readBytes')), isEmpty,
          reason: 'the bridge must not read the source after shutdown');
      expect(os.calls.where((c) => c == 'endBridgedSession()').length, 1,
          reason: 'the session ends exactly once');
    });

    test('shutdown without finishInit: no bridge ever ran', () {
      final os = FakeReplyGuardOs(replyArrives: false);
      final guard = TerminalReplyGuard(os: os)..prepare();
      guard.shutdown(); // teardown before init returned
      expect(guard.bridgeRunning, isFalse);
      expect(guard.bridge.running, isFalse);
    });

    test('shutdown on a never-armed guard: plain no-op', () {
      final os = FakeReplyGuardOs(replyArrives: true);
      final guard = TerminalReplyGuard(os: os)..prepare();
      guard.shutdown();
      expect(guard.bridge.running, isFalse);
    });

    test('mute path with no master: finishInit() starts no bridge', () {
      // masterOnDetour=false models a detour that left no master behind:
      // the guard must not arm a copy loop with nowhere to send bytes.
      final os = FakeReplyGuardOs(
          replyArrives: false, masterOnDetour: false);
      final guard = TerminalReplyGuard(os: os)..prepare();
      guard.finishInit();
      expect(guard.bridgeRunning, isFalse);
      expect(guard.bridge.running, isFalse);
    });

    test('answering terminal: finishInit() never starts a bridge', () {
      final os = FakeReplyGuardOs(replyArrives: true);
      final guard = TerminalReplyGuard(os: os)..prepare();
      guard.finishInit();
      expect(guard.bridgeRunning, isFalse);
      expect(guard.bridge.running, isFalse);
      guard.shutdown(); // no-op
      expect(guard.bridge.running, isFalse);
    });
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);

/// Bytes currently parked in [bridge]'s pending buffer, read via the public
/// test hook rather than reaching into private state.
int bufferedCount(StdinBridge bridge) => bridge.pendingBytes;

/// Scripted [ReplyGuardOs] for driving [StdinBridge] deterministically:
/// stdin reads pop from [stdinQueue], master writes honour a byte budget
/// ([writeBudget] ≤ accepted bytes per write call, 0 = EAGAIN) and can be
/// made to throw. Records every call for choreography assertions.
class _BridgeFakeOs implements ReplyGuardOs {
  _BridgeFakeOs({
    this.stdinQueue = const [],
    this.writeBudget = 99,
    this.throwOnRead = false,
    this.throwOnWrite = false,
  });

  /// Queued stdin payloads; each read consumes one whole entry.
  final List<Uint8List> stdinQueue;

  /// Max bytes each writeBytes accepts; 0 models EAGAIN.
  int writeBudget;

  final bool throwOnRead;
  final bool throwOnWrite;

  int masterFd = 42;

  /// One entry per accepted master write, concatenated in order.
  final writtenToMaster = <String>[];

  final calls = <String>[];

  @override
  bool isTerminal(int fd) => true;

  @override
  void write(int fd, String bytes) {}

  @override
  bool pollReadable(int fd, int timeoutMs) => true;

  @override
  void drain(int fd, int maxBytes) {}

  @override
  Object? enterRawMode(int fd) => 'saved';

  @override
  void restoreMode(int fd, Object? saved) {}

  @override
  bool installDetour(String reply) => true;

  @override
  void beginBridgedSession() {
    calls.add('beginBridgedSession()');
    sourceFd = 7;
  }

  @override
  void endBridgedSession() {
    calls.add('endBridgedSession()');
    sourceFd = -1;
    releaseBridgeMaster();
  }

  @override
  int get bridgeSourceFd => sourceFd;

  @override
  int get bridgeMasterFd => masterFd;

  // The bridge tests drive StdinBridge mid-session, where a real stdin fd
  // is always held; tests that want the stand-down path set this to −1.
  int sourceFd = 7;

  @override
  void releaseBridgeMaster() {
    calls.add('releaseBridgeMaster()');
    masterFd = -1;
  }

  @override
  Uint8List readBytes(int fd, int maxBytes) {
    calls.add('readBytes($fd,$maxBytes)');
    if (throwOnRead) throw StateError('read failed');
    if (stdinQueue.isEmpty) return Uint8List(0);
    return stdinQueue.removeAt(0);
  }

  @override
  int writeBytes(int fd, Uint8List bytes) {
    calls.add('writeBytes($fd,${bytes.length})');
    if (throwOnWrite) throw StateError('write failed');
    if (writeBudget <= 0) return 0;
    final n = bytes.length < writeBudget ? bytes.length : writeBudget;
    writtenToMaster.add(String.fromCharCodes(bytes.sublist(0, n)));
    writeBudget -= n;
    return n;
  }

  @override
  void abandon() {}

  /// Queue size per chunk used by the firehose-cap test. Must match
  /// [StdinBridge.chunkBytes].
  static const int chunkSize = StdinBridge.chunkBytes;

  /// How many oversized single feeds the overflow probe uses (drops oldest).
  static const int overflowProbeBytes =
      StdinBridge.pendingDropLimit + chunkSize;
}

class _ThrowingOs extends FakeReplyGuardOs {
  @override
  bool installDetour(String reply) => throw StateError('boom');
}

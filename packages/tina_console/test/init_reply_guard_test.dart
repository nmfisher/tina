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
  });

  /// fd → is a terminal. Defaults to both stdio being terminals.
  final Map<int, bool> terminals;

  /// Whether the probe reply shows up within the timeout.
  final bool replyArrives;

  /// Whether [enterRawMode] can capture and change the mode.
  final bool rawModeOk;

  /// Whether [installDetour] succeeds.
  final bool detourOk;

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
    return detourOk;
  }

  @override
  void restoreStdin() => calls.add('restoreStdin()');

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

      guard.restore();
      expect(os.calls.last, 'restoreStdin()');
      expect(guard.armed, isFalse, reason: 'restore disarms the guard');
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
      expect(os.calls.any((c) => c == 'restoreStdin()'), isFalse);
    });

    test('answering terminal: restore() is a no-op', () {
      final os = FakeReplyGuardOs(replyArrives: true);
      final guard = TerminalReplyGuard(os: os)..prepare();
      guard.restore();
      expect(os.calls.any((c) => c == 'restoreStdin()'), isFalse);
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
      guard.restore();
      expect(os.calls.any((c) => c == 'restoreStdin()'), isFalse);
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
  });
}

class _ThrowingOs extends FakeReplyGuardOs {
  @override
  bool installDetour(String reply) => throw StateError('boom');
}

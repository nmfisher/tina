import 'package:test/test.dart';
import 'package:tina_console/src/backend/discard_unbinder.dart';

class _FakeOs implements DiscardUnbinderOs {
  _FakeOs({this.bound = true, this.disableOk = true, this.throwOn = ''});

  bool bound;
  bool disableOk;
  String throwOn;
  int isBoundCalls = 0;
  int disableCalls = 0;

  @override
  bool isBound(int fd) {
    if (throwOn == 'isBound') throw StateError('boom');
    isBoundCalls++;
    return bound;
  }

  @override
  bool disable(int fd) {
    if (throwOn == 'disable') throw StateError('boom');
    disableCalls++;
    return disableOk;
  }
}

void main() {
  test('disables when VDISCARD is bound', () {
    final os = _FakeOs();
    expect(DiscardUnbinder.unbind(0, os: os), isTrue);
    expect(os.isBoundCalls, 1);
    expect(os.disableCalls, 1);
  });

  test('no-op when VDISCARD is already unbound (stty discard undef)', () {
    final os = _FakeOs(bound: false);
    expect(DiscardUnbinder.unbind(0, os: os), isFalse);
    expect(os.disableCalls, 0);
  });

  test('false when tcsetattr fails, never throws', () {
    final os = _FakeOs(disableOk: false);
    expect(DiscardUnbinder.unbind(0, os: os), isFalse);
    expect(os.disableCalls, 1);
  });

  test('swallows errors from the OS layer', () {
    for (final where in const ['isBound', 'disable']) {
      final os = _FakeOs(throwOn: where);
      expect(DiscardUnbinder.unbind(0, os: os), isFalse);
    }
  });

  test('fd is plumbed through to both checks', () {
    final fds = <int>[];
    // Reuse the fake to record fds by making bound flip after first call.
    final os = _RecordingOs(fds);
    DiscardUnbinder.unbind(3, os: os);
    expect(fds, [3, 3]);
  });
}

class _RecordingOs implements DiscardUnbinderOs {
  final List<int> fds;
  _RecordingOs(this.fds);

  @override
  bool isBound(int fd) {
    fds.add(fd);
    return true;
  }

  @override
  bool disable(int fd) {
    fds.add(fd);
    return true;
  }
}

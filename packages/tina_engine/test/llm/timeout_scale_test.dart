import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  group('scaledRequestTimeout (#23c)', () {
    test('0 bytes returns the exact base default', () {
      expect(scaledRequestTimeout(0), defaultRequestTimeout);
    });

    test('small payload stays at base (integer division floor)', () {
      // 4095 bytes = 0 full 4096-byte steps → exactly base.
      expect(scaledRequestTimeout(4095), defaultRequestTimeout);
    });

    test('4096 bytes adds exactly 1 second', () {
      expect(
        scaledRequestTimeout(4096),
        Duration(seconds: defaultRequestTimeout.inSeconds + 1),
      );
    });

    test('220KB payload computes exactly per formula', () {
      final kb = 220 * 1024; // 225280 bytes
      final extra = kb ~/ 4096; // 55
      expect(
        scaledRequestTimeout(kb),
        Duration(seconds: defaultRequestTimeout.inSeconds + extra),
      );
    });

    test('monotonic non-decreasing in size', () {
      final a = scaledRequestTimeout(100);
      final b = scaledRequestTimeout(5000);
      final c = scaledRequestTimeout(100000);
      expect(a.inSeconds <= b.inSeconds, isTrue);
      expect(b.inSeconds <= c.inSeconds, isTrue);
    });
  });

  group('scaledStreamIdleTimeout (#24b)', () {
    test('0 bytes returns the exact base default', () {
      expect(scaledStreamIdleTimeout(0), defaultStreamIdleTimeout);
    });

    test('3072 bytes adds exactly 1 second', () {
      expect(
        scaledStreamIdleTimeout(3072),
        Duration(seconds: defaultStreamIdleTimeout.inSeconds + 1),
      );
    });

    test('244KB payload computes exactly per formula', () {
      final kb = 244 * 1024; // 249856 bytes
      final extra = kb ~/ 3072; // 81
      expect(
        scaledStreamIdleTimeout(kb),
        Duration(seconds: defaultStreamIdleTimeout.inSeconds + extra),
      );
    });

    test('monotonic non-decreasing in size', () {
      final a = scaledStreamIdleTimeout(100);
      final b = scaledStreamIdleTimeout(4000);
      final c = scaledStreamIdleTimeout(100000);
      expect(a.inSeconds <= b.inSeconds, isTrue);
      expect(b.inSeconds <= c.inSeconds, isTrue);
    });
  });

  group('caps', () {
    test('900s cap engages for an absurd request size (8MB)', () {
      final huge = 8 * 1024 * 1024; // 8MB
      // Uncapped: 30 + (8*1024*1024 ~/ 4096) ≈ 30 + 2048 = 2078s
      // Capped: 900s
      expect(scaledRequestTimeout(huge), const Duration(seconds: 900));
      expect(scaledStreamIdleTimeout(huge), const Duration(seconds: 900));
    });
  });

  group('integer-division floor behavior', () {
    test('1-byte body adds 0s for both helpers', () {
      expect(scaledRequestTimeout(1).inSeconds, defaultRequestTimeout.inSeconds);
      expect(scaledStreamIdleTimeout(1).inSeconds,
          defaultStreamIdleTimeout.inSeconds);
    });

    test('4097-byte body adds 1s for request helper, 1s for stream', () {
      // 4097 ~/ 4096 = 1; 4097 ~/ 3072 = 1
      expect(
        scaledRequestTimeout(4097),
        Duration(seconds: defaultRequestTimeout.inSeconds + 1),
      );
      expect(
        scaledStreamIdleTimeout(4097),
        Duration(seconds: defaultStreamIdleTimeout.inSeconds + 1),
      );
    });
  });
}

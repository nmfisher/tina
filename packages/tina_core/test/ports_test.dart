import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

void main() {
  test('SystemClock reads the real clock', () {
    final before = DateTime.now();
    final read = const SystemClock().now();
    final after = DateTime.now();
    expect(read.isAfter(before.subtract(const Duration(milliseconds: 1))),
        isTrue);
    expect(read.isBefore(after.add(const Duration(milliseconds: 1))), isTrue);
  });

  test('SystemRandom stays inside the bound and varies', () {
    final random = SystemRandom();
    final seen = <int>{};
    for (var i = 0; i < 32; i++) {
      final value = random.nextInt(256);
      expect(value, inInclusiveRange(0, 255));
      seen.add(value);
    }
    expect(seen.length, greaterThan(1));
  });
}

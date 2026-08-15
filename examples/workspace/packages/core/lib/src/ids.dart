/// Identifier generation.
library;

import 'dart:math';

final class Ids {
  static final Random _random = Random();

  /// The alphabet for generated ids: Crockford base32, minus ambiguous
  /// letters (I, L, O, U).
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Generates a sortable, 26-character id: 13 chars of millisecond
  /// timestamp (big-endian) followed by 13 chars of randomness.
  static String newId([int? nowMillis]) {
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final ts = now.toRadixString(32).toUpperCase().padLeft(13, '0');
    final rand = List.generate(
      13,
      (_) => _alphabet[_random.nextInt(_alphabet.length)],
    ).join();
    return '$ts$rand';
  }
}

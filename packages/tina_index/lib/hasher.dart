/// FNV-1a 64-bit content hasher for content-addressable storage.
class CodeHasher {
  static int _fnv1a64(List<int> bytes) {
    const int basis = 0xCBF29CE484222325;
    const int prime = 0x100000001B3;
    int hash = basis;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash;
  }

  /// Returns a 16-char hex string hash of [bytes].
  static String hashBytes(List<int> bytes) {
    return _fnv1a64(bytes).toRadixString(16).padLeft(16, '0');
  }

  /// Returns a 16-char hex string hash of [text] encoded as UTF-8.
  static String hashText(String text) {
    return hashBytes(text.codeUnits);
  }
}

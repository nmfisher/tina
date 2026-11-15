/// The boot preload walk's admission decisions: bounded and lazy on
/// purpose. Kept free of any wasm-component import so the numbers and
/// boundary behavior are unit-testable on the plain VM — the walk itself
/// drives the `wasi:filesystem` port and only runs compiled to wasm.
///
/// Why bounds at all: the walk used to read EVERY regular file fully
/// into Latin1 strings before the assembly booted (`String.fromCharCodes`
/// → `Latin1String.fromAsciiBytes` → `cloneTyped`), so a large file under
/// the preopen roots — with the real preopen layout the `.tina` root
/// resolves to the WORKSPACE ROOT, so that means a large file anywhere in
/// the workspace — trapped the guest at boot. A file refused here stays
/// on disk; the agent's file tools and the session store read through the
/// WASI port directly and never consult the preload snapshot, so a skip
/// costs boot memory, not functionality.
library;

import 'dart:typed_data';

final class PreloadBudget {
  /// Per-file cap: a larger file is never even opened during the walk,
  /// only statted. 2MB is ~1000x a real settings document; anything
  /// past it under the walked roots is bulk data.
  static const int defaultMaxFileBytes = 2 * 1024 * 1024;

  /// Cumulative cap: once this many bytes are preloaded, later files are
  /// only enumerated (for exists()/directory discovery), never read.
  /// 64MB of preloaded strings stays far below any wasm memory ceiling
  /// while covering every sane config tree many times over.
  static const int defaultMaxTotalBytes = 64 * 1024 * 1024;

  /// Binary sniff window: a NUL byte anywhere in the first 8KB marks the
  /// file binary — Latin1 string conversion of binary data is pure
  /// memory waste. (A NUL past the window does not count: the sniff is a
  /// cheap heuristic, not a format detector.)
  static const int defaultBinarySniffWindow = 8 * 1024;

  PreloadBudget({
    int? maxFileBytes,
    int? maxTotalBytes,
    int? binarySniffWindow,
  })  : maxFileBytes = maxFileBytes ?? defaultMaxFileBytes,
        maxTotalBytes = maxTotalBytes ?? defaultMaxTotalBytes,
        binarySniffWindow = binarySniffWindow ?? defaultBinarySniffWindow;

  final int maxFileBytes;
  final int maxTotalBytes;
  final int binarySniffWindow;

  int _preloadedBytes = 0;

  /// Bytes admitted into the snapshot so far.
  int get preloadedBytes => _preloadedBytes;

  bool _exhausted = false;

  /// True once the cumulative budget refused a file; every later file is
  /// skipped without reading (the walk keeps enumerating for discovery).
  bool get exhausted => _exhausted;

  /// The stat-time decision: may the walk open and read this file of
  /// [size] bytes? False means skip it (oversized, already exhausted, or
  /// it would push the total past the budget).
  bool admitStatSize(int size) {
    if (_exhausted) return false;
    if (size > maxFileBytes) return false;
    if (_preloadedBytes + size > maxTotalBytes) {
      _exhausted = true;
      return false;
    }
    return true;
  }

  /// The read-time decision (the file may have grown between stat and
  /// read; the read size is authoritative). On true the [length] bytes
  /// are recorded against the budget.
  bool admitReadBytes(int length) {
    if (_exhausted) return false;
    if (length > maxFileBytes) return false;
    if (_preloadedBytes + length > maxTotalBytes) {
      _exhausted = true;
      return false;
    }
    _preloadedBytes += length;
    return true;
  }

  /// Gives back [length] bytes previously recorded by [admitReadBytes] —
  /// used when a fully-read file turns out binary and contributes no
  /// string to the snapshot, so binary bulk must not silently eat the
  /// budget either.
  void releaseBytes(int length) {
    _preloadedBytes -= length;
    if (_preloadedBytes < 0) _preloadedBytes = 0;
  }

  /// The text-shape decision: does [data] look binary (a NUL byte in the
  /// first [binarySniffWindow] bytes)?
  bool looksBinary(Uint8List data) {
    final window = data.length < binarySniffWindow
        ? data
        : Uint8List.sublistView(data, 0, binarySniffWindow);
    return window.contains(0);
  }
}

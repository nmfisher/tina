/// The no-`dart:io` variant of `history_reader_io.dart` (wasm
/// compilation): a shape-compatible stub — the real reader opens the
/// sqlite session store with `dart:ffi`, which a component does not have.
/// Session history search is native-only; the wasm session store rides the
/// injected `WasiSessionStore` seam instead.
library;

import 'store.dart';

final class HistoryReader {
  HistoryReader(String file) {
    throw UnsupportedError(
        'the sqlite history reader is native-only; wasm uses the injected '
        'WasiSessionStore seam');
  }

  /// Mirrors the real reader's schema check against the same marker.
  static const schemaVersion = SessionStore.schemaVersion;

  Never _refuse() => throw UnsupportedError(
      'the sqlite history reader is native-only; wasm uses the injected '
      'WasiSessionStore seam');

  void close() {}

  List<Map<String, Object?>> search(
      {required String query,
      required String? excludeSession,
      required int limit,
      bool orderByTime = false}) {
    return _refuse();
  }

  Map<String, Object?> read(String sessionId,
      {required int? beforeSeq,
      required int limit,
      int? messageSeq,
      int textOffset = 0}) {
    return _refuse();
  }
}

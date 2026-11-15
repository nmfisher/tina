/// The no-`dart:io` variant of `store.dart` (wasm compilation): the
/// sqlite-backed [SessionStore] becomes a shape-compatible stub — the wasm
/// session store is `WasiSessionStore` (the injected seam), never this
/// class. Re-exports `session_store_api.dart` exactly like the native
/// file, so the barrel's surface is unchanged.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_settings/tina_settings.dart';

import '../session_store_api.dart';

export '../session_store_api.dart';

final class SessionStore implements SessionStoreApi {
  SessionStore._(this.file);

  /// Never succeeds under wasm: opening a store needs sqlite (dart:ffi).
  /// The wasm composition root injects `WasiSessionStore` instead.
  static SessionStore open(String path) => throw UnsupportedError(
      'the sqlite session store is native-only; wasm uses the injected '
      'WasiSessionStore seam');

  /// Mirrors the real store's schema marker so a stub-typed reader keeps
  /// compiling against the same surface.
  static const schemaVersion = 2;

  @override
  final String file;

  Never _refuse() =>
      throw UnsupportedError('sqlite session store is native-only');

  @override
  int createSession(String id,
          {String? title,
          String? model,
          SessionDetails? details,
          List<SessionEntry> entries = const []}) =>
      _refuse();

  @override
  void append(String sessionId, List<SessionEntry> entries) => _refuse();

  @override
  void updateDetails(String sessionId, SessionDetails details,
          {String? model}) =>
      _refuse();

  /// Mirrors the real store's legacy-import entry point (native-only on
  /// wasm; legacy_import compiles against the shape).
  bool importSnapshot(
    String id, {
    required String fingerprint,
    required Map<String, Object?> provenance,
    required List<SessionEntry> entries,
    String? title,
  }) =>
      _refuse();

  @override
  List<StoredSession> list() => _refuse();

  @override
  List<SessionEntry> readEntries(String sessionId) => _refuse();

  @override
  List<StoreGap> checkGaps(String sessionId) => _refuse();

  @override
  SessionDetails readDetails(String sessionId) => _refuse();

  @override
  void close() => _refuse();
}

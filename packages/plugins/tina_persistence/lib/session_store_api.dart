/// The session-store contract, with no sqlite anywhere: the interface
/// the persistence plugin consumes, the portable value types every
/// implementation shares, and the settings-replay helper.
///
/// `store.dart`'s sqlite-backed [SessionStore] implements this natively;
/// a wasm composition root implements it over preopened files. This
/// library must stay importable where `dart:ffi` cannot go: its import
/// graph is `tina_core`, `tina_settings` and nothing else.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_settings/tina_settings.dart'
    show ScopedSettings, SettingScope;

/// The store link failed — at open, at write, or mid-read. The host does
/// not swallow this: a store that cannot persist must stop the session
/// loudly, because a session that lies about durability is worse than
/// none.
final class SessionStoreException implements Exception {
  const SessionStoreException(this.message, [this.cause]);

  final String message;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'SessionStoreException: $message${cause == null ? '' : ' ($cause)'}';
}

/// One session the store knows about.
final class StoredSession {
  const StoredSession({
    required this.id,
    required this.registryKey,
    required this.entries,
    int? lastActivityKey,
    this.title,
    this.model,
    this.details,
    this.lastSavedAt,
    this.summary,
  }) : lastActivityKey = lastActivityKey ?? registryKey;

  /// The session id the host started it with.
  final String id;

  /// The registry row where the session's slice begins.
  final int registryKey;

  /// Most recent registry, metadata or entry row for this session. Row order
  /// reflects local activity, including appends to a resumed conversation.
  final int lastActivityKey;

  /// How many log rows follow the registry row (a lower bound while the
  /// session is still running in another process: this reader sees the
  /// rows committed when it read).
  final int entries;

  /// The title given at creation, when there was one.
  final String? title;
  final String? model;

  /// Timestamp of the latest committed registry, metadata or entry row.
  /// Derived from the existing SQLite log, so older stores need no migration.
  final DateTime? lastSavedAt;

  /// A short preview of the first user input, independent of generated output.
  final String? summary;

  /// The session's counters (depth, children in flight, tokens spent)
  /// as the registry row carries them, or null when the row predates
  /// details.
  final SessionDetails? details;

  @override
  String toString() => 'StoredSession($id, $entries entries'
      '${title == null ? '' : ', $title'})';
}

/// A run of rowids that is not consecutive inside one session's slice.
final class StoreGap {
  const StoreGap(this.afterId, this.beforeId);

  /// The rowid before the hole.
  final int afterId;

  /// The rowid after the hole.
  final int beforeId;

  @override
  String toString() => 'gap: no rows between $afterId and $beforeId';
}

/// The store surface the persistence plugin uses. One store owns one
/// file; [createSession] registers a session (with its first entries),
/// [append] extends it, [updateDetails] revises its metadata, and the
/// readers serve resume and listing. Implementations keep the slice
/// semantics: strictly increasing store order, a session's `seq` run
/// reads 0, 1, 2, ….
abstract interface class SessionStoreApi {
  /// The store file's path (store-native string).
  String get file;

  /// Register [id] with its first [entries], returning the registry key.
  int createSession(String id,
      {String? title,
      String? model,
      SessionDetails? details,
      List<SessionEntry> entries = const []});

  /// Extend the session's slice; entries must continue its `seq` run.
  void append(String sessionId, List<SessionEntry> entries);

  /// Revise the session's stored details and model.
  void updateDetails(String sessionId, SessionDetails details,
      {String? model});

  /// Every session in the store, with its entry count.
  List<StoredSession> list();

  /// The session's entries in order.
  List<SessionEntry> readEntries(String sessionId);

  /// Holes in the session's slice — corruption, by construction.
  List<StoreGap> checkGaps(String sessionId);

  /// The session's stored details.
  SessionDetails readDetails(String sessionId);

  /// Release the store's resources.
  void close();
}

/// Opens a store: the injection point an assembly passes to the plugin.
typedef SessionStoreOpener = SessionStoreApi Function();

/// Interpret the persistence plugin's own settings snapshot before
/// factories are built: replay the session-scoped settings overrides a
/// persisted session carried. (The sqlite plugin's static
/// `restoreSettings` delegates here — one definition, both stores.)
void restoreSessionSettingsFromLog(
    ScopedSettings settings, Iterable<SessionEntry> log) {
  PluginStateEntry? snapshot;
  for (final entry in log) {
    if (entry is PluginStateEntry &&
        entry.pluginId == 'tina/persistence' &&
        entry.stateKey == 'settings') snapshot = entry;
  }
  if (snapshot == null) return;
  if (snapshot.schemaVersion != 1) {
    throw const FormatException('Unsupported session settings version');
  }
  final values = snapshot.value?['overrides'] as Map? ?? {};
  settings.backend
      .write(SettingScope.session, Map<String, Object?>.from(values));
  settings.reload();
}

/// Read-time normalization only. Historical database rows are never rewritten.
/// Payload schemas remain the responsibility of the owning plugin's codec.
SessionEntry decodePersistedEntry(Map<String, dynamic> json) {
  final owner = switch (json['type']) {
    'plan_changed' => ('tina/plans', 'plan'),
    'goal_changed' => ('tina/goals', 'goal'),
    'workflow_run' => ('tina/workflows', 'last-run'),
    'mode_changed' => ('tina/mode', 'permission-mode'),
    _ => null,
  };
  if (owner == null) return SessionEntry.fromJson(json);
  final value = Map<String, dynamic>.from(json)
    ..remove('type')
    ..remove('seq')
    ..remove('at');
  if (json['type'] == 'mode_changed' && value['mode'] == 'normal')
    value['mode'] = 'ask';
  return PluginStateEntry.snapshot(
      pluginId: owner.$1,
      stateKey: owner.$2,
      schemaVersion: 1,
      value: value,
      seq: json['seq'] as int? ?? 0,
      at: json['at'] as String? ?? '');
}

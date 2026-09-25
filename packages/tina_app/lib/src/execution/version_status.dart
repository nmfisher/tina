import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import 'input_status.dart';

/// The single live version-check tracker, provided by [versionStatusPlugin]
/// under this key. The frontend's composition plugin requires the same key to
/// contribute the source and renderer that display it on the status strip; the
/// coordinator (TUI) or headless runs without it simply look the key up as
/// null and skip the indicator.
final versionStatusServiceKey = ServiceKey<VersionStatus>(
  'tina.version.status',
);

/// Strip view-model for the release check. Value-shaped so the renderer stays
/// a pure function of it. (No `idle` member: a null snapshot from
/// [VersionStatus.read] means idle, which removes the line entirely.)
/// [VersionPhase.miss] is the honest third answer — the check ran but could
/// not reach GitHub, so "no alert" must not read as "up to date";
/// [VersionPhase.deferred] is the quiet fourth — the probe was skipped to
/// respect a server-indicated retry window.
enum VersionPhase { checking, updateAvailable, miss, deferred }

class VersionSnapshot {
  final VersionPhase phase;
  final String? tag;
  final String? why;

  /// The last known release tag (`null` when nothing is cached) — the
  /// miss/deferred suffix, e.g. `update check failed — HTTP 403 · last known
  /// v0.8.32`.
  final String? previousTag;

  const VersionSnapshot.checking()
    : phase = VersionPhase.checking,
      tag = null,
      why = null,
      previousTag = null,
      until = null;
  const VersionSnapshot.updateAvailable(this.tag)
    : phase = VersionPhase.updateAvailable,
      why = null,
      previousTag = null,
      until = null,
      assert(tag != null);

  /// [why] is a short human phrase, e.g. `HTTP 403 (likely rate-limited)` or
  /// `Connection refused`.
  const VersionSnapshot.miss(this.why, {this.previousTag})
    : phase = VersionPhase.miss,
      tag = null,
      until = null;

  /// [until] is the defer deadline; [previousTag] the last known release tag
  /// when one is cached.
  const VersionSnapshot.deferred({this.until, this.previousTag})
    : phase = VersionPhase.deferred,
      tag = null,
      why = null;

  /// Defer deadline ([VersionPhase.deferred] only).
  final DateTime? until;
}

/// Live release-check state for the status strip, exposed as a [StatusSource]
/// (read null while idle, which removes the line). App-scoped: there is one
/// release check per process, so every conversation reads the same snapshot.
/// Fed by the coordinator's background check (or a test); the strip subscribes
/// through the frontend's composition plugin.
class VersionStatus implements StatusSource {
  VersionSnapshot? _snapshot;
  final _changes = StreamController<void>.broadcast();

  /// Whether a check is currently in flight (a revalidation round-trip keeps
  /// the spinner up when the cached answer was "not newer").
  bool get checking => _snapshot?.phase == VersionPhase.checking;

  /// Mark the release check started.
  void beginCheck() {
    _snapshot = const VersionSnapshot.checking();
    _changes.add(null);
  }

  /// The check settled on "up to date". The line leaves the strip — that is
  /// the one outcome that should read as silence.
  void upToDate() {
    if (_snapshot == null) return;
    _snapshot = null;
    _changes.add(null);
  }

  /// The check ran but could not reach GitHub ([why] is the short reason,
  /// e.g. `HTTP 403 (likely rate-limited)`). Paints a dim miss line so the
  /// failure is visible; a yellow alert never hides behind it — a later
  /// check that finds a release replaces it via [updateAvailable].
  /// [previousTag], when known, suffixes the line with the last known tag.
  void missed(String why, {String? previousTag}) {
    _snapshot = VersionSnapshot.miss(why, previousTag: previousTag);
    _changes.add(null);
  }

  /// The background check was skipped: a previous session's failed fetch
  /// recorded a defer window (rate limit / outage), and respecting it beats
  /// burning the shared API budget. Strip-only state — no chat notice; the
  /// failure already announced itself the session it happened.
  void deferred(DateTime? until, {String? release}) {
    _snapshot = VersionSnapshot.deferred(until: until, previousTag: release);
    _changes.add(null);
  }

  /// The check found a newer release.
  void updateAvailable(String tag) {
    _snapshot = VersionSnapshot.updateAvailable(tag);
    _changes.add(null);
  }

  @override
  Object? read(String conversationId) => _snapshot;

  @override
  Stream<void> get changes => _changes.stream;

  /// Release the change stream. Called by the providing scope at teardown.
  void close() => _changes.close();
}

/// Provides the app-wide [VersionStatus] under [versionStatusServiceKey].
/// Mounted by the interactive composition (bin/tina.dart); the strip plugin
/// requires the same key to contribute the source and renderer that display
/// it, and the coordinator feeds the service from the background check. Runs
/// that never check (headless, or COCOON_UPDATE_CHECK=0) mount it harmlessly:
/// the service just stays idle and the strip shows nothing.
PluginDescriptor versionStatusPlugin() => PluginDescriptor(
  id: 'tina.version-status-service',
  provides: [versionStatusServiceKey],
  factory: FnPluginFactory((context) {
    final status = VersionStatus();
    context.own(status.close);
    return status;
  }),
);

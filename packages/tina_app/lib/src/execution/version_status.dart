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
enum VersionPhase { checking, updateAvailable }

class VersionSnapshot {
  final VersionPhase phase;
  final String? tag;

  const VersionSnapshot.checking()
      : phase = VersionPhase.checking,
        tag = null;
  const VersionSnapshot.updateAvailable(this.tag)
      : phase = VersionPhase.updateAvailable,
        assert(tag != null);
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

  /// The check settled on "up to date" (or failed — a network miss is silent
  /// by design and reads as idle). The line leaves the strip.
  void upToDate() {
    if (_snapshot == null) return;
    _snapshot = null;
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

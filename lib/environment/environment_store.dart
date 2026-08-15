import 'dart:convert';
import 'dart:io';

import 'environment_inputs.dart';

/// The machine-owned tracking entry for the environment region, at
/// `<projectRoot>/.tina/environment/tracking.json` — inside the gitignored
/// `.tina` sidecar, outside the main repo's tracked tree.
///
/// This is the one piece of environment state the agent never writes
/// (docs/proposals/environment_agent.md, "Region integration"): however wrong
/// the record's prose gets, the stale/fresh verdict recorded here stays
/// trustworthy, and the warm-load `status:` line renders from it. "These inputs
/// were measured at this commit, now" is the only machine-guaranteed fact —
/// everything in `ENVIRONMENT.md` is a claim.
class EnvironmentTrackingStore {
  EnvironmentTrackingStore({
    required this.projectRoot,
    EnvironmentInputs? inputs,
  }) : _inputs = inputs ?? const EnvironmentInputs();

  final String projectRoot;
  final EnvironmentInputs _inputs;

  /// `.tina/environment/` — the sidecar dir for this feature.
  Directory get root => Directory('$projectRoot/.tina/environment');

  File get _file => File('${root.path}/tracking.json');

  /// The last recorded measurement, or null when none exists (first load, or
  /// a failed run that correctly recorded nothing and left the region stale).
  EnvironmentTrackingEntry? load() {
    final file = _file;
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return EnvironmentTrackingEntry.fromJson(json);
    } on FormatException {
      // Corrupt entry: treat as unmeasured (stale) rather than blocking.
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Measure the inputs now and record the entry. Dart-only writer: called by
  /// the runner after an environment-agent run, never by the agent. Best-effort
  /// on write (a read-only sidecar must not fail the run) — an unwritten entry
  /// just leaves the region stale.
  EnvironmentTrackingEntry record() {
    final state = _inputs.measure(projectRoot);
    final entry = EnvironmentTrackingEntry(
      commit: state.commit,
      inputsDigest: state.committed,
      dirtyDigest: state.dirty,
      measuredAt: DateTime.now().toIso8601String(),
    );
    try {
      root.createSync(recursive: true);
      _file.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(entry.toJson()));
    } on FileSystemException {
      // Ignored by design (see doc comment).
    }
    return entry;
  }

  /// Why the region is stale, or null when it is current. Stale when no entry
  /// exists (never measured, or the last run failed), or either digest moved —
  /// the record was edited, a dependency changed, or the working tree did.
  String? staleReason() {
    final entry = load();
    if (entry == null) return 'never measured';
    final now = _inputs.measure(projectRoot);
    if (entry.inputsDigest != now.committed) {
      return 'inputs changed since the last measurement';
    }
    if (entry.dirtyDigest != now.dirty) {
      return 'working tree changed since the last measurement';
    }
    return null;
  }

  /// Whether the region is stale (see [staleReason]).
  bool get isStale => staleReason() != null;
}

/// One recorded measurement of the environment region's inputs.
class EnvironmentTrackingEntry {
  final String commit;
  final String inputsDigest;
  final String dirtyDigest;
  final String measuredAt;

  const EnvironmentTrackingEntry({
    required this.commit,
    required this.inputsDigest,
    required this.dirtyDigest,
    required this.measuredAt,
  });

  Map<String, dynamic> toJson() => {
        'commit': commit,
        'inputsDigest': inputsDigest,
        'dirtyDigest': dirtyDigest,
        'measuredAt': measuredAt,
      };

  factory EnvironmentTrackingEntry.fromJson(Map<String, dynamic> json) =>
      EnvironmentTrackingEntry(
        commit: json['commit'] as String? ?? '',
        inputsDigest: json['inputsDigest'] as String? ?? '',
        dirtyDigest: json['dirtyDigest'] as String? ?? '',
        measuredAt: json['measuredAt'] as String? ?? '',
      );
}

import 'package:tina_engine_2/tina_engine_2.dart' show SessionEntry;

/// An owner supplies a public, JSON-only projection of a feature. Reading must
/// be synchronous and side-effect free. Credentials and mutation capabilities
/// must never be included. The host owns only the observation subscription.
final class SnapshotFeature {
  const SnapshotFeature(this.read, {this.listen, this.historyMetadata});
  final Map<String, Object?> Function() read;
  final void Function() Function(void Function())? listen;

  /// Optional public metadata for one committed entry (for example tool
  /// descriptions). Receives a detached entry; never replaces the entry or
  /// writes another transcript.
  final Map<String, Object?> Function(SessionEntry)? historyMetadata;
}

/// Copy JSON data without calling arbitrary toJson methods or retaining any
/// mutable nested collections. Invalid feature data is reported as unavailable.
Object? freezeSnapshotValue(Object? value) => switch (value) {
      null || String() || bool() || int() => value,
      double() when value.isFinite => value,
      Map() => Map<String, Object?>.unmodifiable(
            value.map<String, Object?>((key, item) {
          if (key is! String)
            throw ArgumentError('Snapshot keys must be strings');
          return MapEntry(key, freezeSnapshotValue(item));
        })),
      List() => List<Object?>.unmodifiable(value.map(freezeSnapshotValue)),
      _ => throw ArgumentError('Snapshot values must be JSON data'),
    };

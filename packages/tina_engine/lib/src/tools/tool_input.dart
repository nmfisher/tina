import 'package:path/path.dart' as p;

import 'tool.dart';

/// Thrown by the shared input helpers when a tool's input map is missing a
/// required field or holds a wrong-typed value. Tools catch this and surface it
/// verbatim via [ToolResult.error]; callers should not need to handle it.
class ToolValidationException implements Exception {
  final String message;
  const ToolValidationException(this.message);

  @override
  String toString() => message;
}

/// Reads a required, non-empty string field. Throws [ToolValidationException]
/// with `'$key is required'` if absent, null, empty, or not a string — matching
/// the phrasing every tool already used by hand.
String requiredString(Map<String, dynamic> input, String key) {
  final value = input[key];
  if (value is String && value.isNotEmpty) return value;
  throw ToolValidationException('$key is required');
}

/// Reads an optional string field, or `null` if absent/not a string.
String? optionalString(Map<String, dynamic> input, String key) {
  final value = input[key];
  return value is String ? value : null;
}

/// Reads an optional int field, or `null` if absent/not an int.
int? optionalInt(Map<String, dynamic> input, String key) {
  final value = input[key];
  return value is int ? value : null;
}

/// Reads an optional bool field, or `null` if absent/not a bool.
bool? optionalBool(Map<String, dynamic> input, String key) {
  final value = input[key];
  return value is bool ? value : null;
}

/// Resolve a model-supplied path against the owning runtime, when scoped.
String resolveToolPath(String path, String? projectRoot) =>
    projectRoot == null || p.isAbsolute(path)
        ? path
        : p.normalize(p.join(projectRoot, path));

/// A deeply unmodifiable view of a tool-call input map.
///
/// [ToolExecutor] snapshots the model's JSON arguments with [snapshotToolInput]
/// and then hands out views built by [asDeepUnmodifiable] so a hook or observer
/// can never mutate the arguments the policy approved and the tool will run
/// with. The values are wrapped, not copied: the view reflects the snapshot it
/// wraps, and the snapshot itself is never handed out.
Map<String, dynamic> asDeepUnmodifiable(Map<String, dynamic> map) =>
    Map.unmodifiable({
      for (final entry in map.entries)
        entry.key: _unmodifiableValue(entry.value),
    });

dynamic _unmodifiableValue(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String? ?? entry.key: _unmodifiableValue(entry.value),
    });
  }
  if (value is List) {
    return List.unmodifiable([for (final item in value) _unmodifiableValue(item)]);
  }
  return value;
}

/// A private, detached copy of the model's tool-call arguments.
///
/// Called ONCE per dispatch, before authorization: every later reader — the
/// policy, the approval prompt, the hooks, the observers, the tool itself —
/// sees exactly these values, so a caller (or hook) mutating the original map
/// during an approval wait cannot change what executes.
Map<String, dynamic> snapshotToolInput(Map<String, dynamic> input) =>
    _copyValue(input) as Map<String, dynamic>;

dynamic _copyValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key as String? ?? entry.key: _copyValue(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _copyValue(item)];
  }
  return value;
}

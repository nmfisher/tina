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

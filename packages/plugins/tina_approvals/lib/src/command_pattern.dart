/// A user-reviewed regular expression for a complete command string.
/// Anchors are supplied here, including a strict end-of-input assertion.
final class CommandApprovalPattern {
  CommandApprovalPattern(this.pattern) {
    if (pattern.isEmpty || pattern.length > 2048) {
      throw const FormatException('Use a regex between 1 and 2048 characters.');
    }
    if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(pattern)) {
      throw const FormatException(r'Use escaped controls such as \n or \t.');
    }
    // Validate on its own first: an unfinished character class must not absorb
    // the anchors we add. Unicode mode rejects legacy malformed-pattern escapes.
    RegExp(pattern, unicode: true);
    _regex = RegExp('^(?:$pattern)\$(?![\\s\\S])', unicode: true);
  }

  final String pattern;
  late final RegExp _regex;

  /// Escape a literal command into an editable single-line regex, including
  /// newlines and other controls that RegExp.escape leaves verbatim.
  static String escape(String command) =>
      RegExp.escape(command).replaceAllMapped(RegExp(r'[\x00-\x1f\x7f-\x9f]'),
          (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}');

  bool matches(String command) => _regex.hasMatch(command);

  void requireMatch(String command) {
    if (!matches(command)) {
      throw const FormatException('The regex must match the entire command.');
    }
  }
}

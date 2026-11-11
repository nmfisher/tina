/// The box allowlist: the one list. Plain text, versioned, readable and
/// editable by the user; one file per project plus one global file.
///
/// Format (v1):
///
/// ```text
/// # tina box allowlist v1
/// # One rule per line: <glob> -> <box[/profile]>
/// # boxes: 1 read-only, 2 contained, 3 ask; profiles: scripts build packages default
/// dart test* -> 2/build
/// curl http* -> 3
/// ```
///
/// The first non-comment line must be `version 1`; anything else ignores
/// the whole file (and surfaces as an error, never a crash). Rule lines
/// are `<glob> -> <verdict>` where verdict is `1`, `3` or `2/<profile>`.
/// Globs match the command line the approval dialog shows
/// (`fileGlobMatchCommand`: `*` spans spaces). A stored rule names the
/// box/profile future matches run in, without asking again.
///
/// Damaged lines are skipped and reported, not fatal: a user-edited file
/// must never break the agent. Every lookup rereads disk, so editing the
/// file takes effect on the next command.
library;

import 'dart:io';

import 'box_model.dart';

/// Glob-match a command line for the allowlist: `*` spans any characters —
/// spaces and slashes included, because a command line is not a path — and
/// `?` any single character. Everything else is literal. Deliberately
/// simpler than a regex: the file is meant to be hand-edited.
bool boxPatternMatch(String pattern, String line) {
  final buffer = StringBuffer('^');
  for (var index = 0; index < pattern.length; index++) {
    final character = pattern[index];
    if (character == '*') {
      buffer.write('.*');
    } else if (character == '?') {
      buffer.write('.');
    } else if (r'.+^$(){}[]|\'.contains(character)) {
      buffer.write('\\$character');
    } else {
      buffer.write(character);
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString(), dotAll: true).hasMatch(line);
}

/// One stored rule.
final class BoxRule {
  const BoxRule(
      {required this.pattern, required this.box, required this.profile});

  final String pattern;
  final Box box;

  /// The profile box-2 matches run in; null for boxes 1 and 3.
  final BoxProfileSpec? profile;

  /// The verdict text as it appears in the file (`1`, `3`, `2/build`).
  String get verdict =>
      profile == null ? box.label : '${box.label}/${profile!.name}';

  @override
  String toString() => '$pattern -> $verdict';
}

const _header = <String>[
  '# tina box allowlist v1',
  '# One rule per line: <glob> -> <box[/profile]>',
  '# boxes: 1 read-only, 2 contained, 3 ask; profiles: scripts build packages default',
];

/// Parses one rule line (`dart test* -> 2/build`), or null when invalid.
BoxRule? parseBoxRule(String line) {
  final arrow = line.indexOf('->');
  if (arrow <= 0) return null;
  final pattern = line.substring(0, arrow).trim();
  final verdict = line.substring(arrow + 2).trim();
  if (pattern.isEmpty || pattern.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    return null;
  }
  switch (verdict) {
    case '1':
      return BoxRule(pattern: pattern, box: Box.readOnly, profile: null);
    case '3':
      return BoxRule(pattern: pattern, box: Box.ask, profile: null);
  }
  if (!verdict.startsWith('2/')) return null;
  final profile = boxProfiles[verdict.substring(2).trim()];
  if (profile == null) return null;
  return BoxRule(
      pattern: pattern, box: Box.contained, profile: profile);
}

/// Formats one rule line for the file (round-trips through
/// [parseBoxRule]).
String formatBoxRule(String pattern, Box box, BoxProfileSpec? profile) =>
    BoxRule(pattern: pattern, box: box, profile: profile).toString();

/// Both files: project rules are consulted before global rules.
final class BoxAllowlist {
  BoxAllowlist._(this._project, this._global);

  final File? _project;
  final File? _global;
  List<BoxRule> _rules = const [];
  List<String> _errors = const [];

  /// Every loaded rule, project file first. Unmodifiable.
  List<BoxRule> get rules => List.unmodifiable(_rules);

  /// Parse problems from the last load. Surfaced once by the host; never
  /// fatal.
  List<String> get errors => List.unmodifiable(_errors);

  /// Reads both files. Missing files are fine (an empty list); damaged
  /// files surface as errors.
  static BoxAllowlist load({File? project, File? global}) {
    return BoxAllowlist._(project, global).._reload();
  }

  void _reload() {
    final rules = <BoxRule>[];
    final errors = <String>[];
    for (final file in [_project, _global]) {
      if (file == null) continue;
      _parse(file, rules, errors);
    }
    _rules = rules;
    _errors = errors;
  }

  void _parse(File file, List<BoxRule> rules, List<String> errors) {
    if (!file.existsSync()) return;
    final lines = file.readAsLinesSync();
    var version = false;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (!version) {
        if (line == 'version 1') {
          version = true;
          continue;
        }
        errors.add('${file.path}: missing "version 1" header; file ignored');
        return;
      }
      final rule = parseBoxRule(line);
      if (rule == null) {
        errors.add('${file.path}:${index + 1}: unrecognized rule "$line"');
        continue;
      }
      rules.add(rule);
    }
  }

  /// The first rule whose pattern matches [commandLine], or null.
  /// Rereads the files so user edits take effect immediately.
  BoxRule? match(String commandLine) {
    _reload();
    for (final rule in _rules) {
      if (boxPatternMatch(rule.pattern, commandLine)) return rule;
    }
    return null;
  }

  /// Appends one rule. [global] picks the global file; otherwise the
  /// project file (a global-only installation without a project file
  /// writes the global file).
  void remember(String pattern, Box box, BoxProfileSpec? profile,
      {bool global = false}) {
    final line = formatBoxRule(pattern, box, profile);
    // Round-trip guard: never write a line the loader cannot read back.
    if (parseBoxRule(line) == null) {
      throw FormatException('Invalid box allowlist rule: $line');
    }
    final target = global ? _global ?? _project : _project ?? _global;
    if (target == null) {
      throw StateError('No box allowlist file is configured');
    }
    target.parent.createSync(recursive: true);
    final existing = target.existsSync() ? target.readAsStringSync() : null;
    final body = existing == null || !existing.contains('version 1')
        ? '${[..._header, 'version 1', line].join('\n')}\n'
        : existing.endsWith('\n')
            ? '$existing$line\n'
            : '$existing\n$line\n';
    target.writeAsStringSync(body, flush: true);
    _reload();
  }
}

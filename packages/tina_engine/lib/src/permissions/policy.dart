enum PermissionDecision { allow, deny, ask }

class PermissionRule {
  final String toolName;
  final String pattern;
  final PermissionDecision decision;

  const PermissionRule({
    required this.toolName,
    required this.pattern,
    required this.decision,
  });

  @override
  String toString() => '${decision.name}: $toolName:$pattern';

  /// Wire shape for persistence. [decision] round-trips via its enum name.
  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'pattern': pattern,
        'decision': decision.name,
      };

  factory PermissionRule.fromJson(Map<String, dynamic> j) => PermissionRule(
        toolName: j['toolName'] as String,
        pattern: j['pattern'] as String,
        decision:
            PermissionDecision.values.byName(j['decision'] as String),
      );
}

class PermissionPolicy {
  final Map<String, PermissionDecision> defaults;
  final List<PermissionRule> staticRules;
  final List<PermissionRule> sessionRules = [];

  PermissionPolicy({
    Map<String, PermissionDecision>? defaults,
    List<PermissionRule>? rules,
  })  : defaults = Map.from(defaults ?? _builtinDefaults),
        staticRules = List.unmodifiable(rules ?? const []);

  static const _builtinDefaults = {
    'read': PermissionDecision.allow,
    'write': PermissionDecision.ask,
    'edit': PermissionDecision.ask,
    'bash': PermissionDecision.ask,
  };

  PermissionDecision check(String tool, Map<String, dynamic> input) {
    final key = keyFor(tool, input);
    // Session memory wins over static rules; latest decision wins within it.
    for (final r in sessionRules.reversed) {
      if (_appliesTo(r, tool, key)) return r.decision;
    }
    for (final r in staticRules) {
      if (_appliesTo(r, tool, key)) return r.decision;
    }
    return defaults[tool] ?? PermissionDecision.ask;
  }

  void remember(String tool, String pattern, PermissionDecision decision) {
    sessionRules.add(PermissionRule(
      toolName: tool,
      pattern: pattern,
      decision: decision,
    ));
  }

  /// What this tool call boils down to for matching / display purposes.
  /// For bash it's the command string; for file tools it's the file path.
  static String keyFor(String tool, Map<String, dynamic> input) {
    if (tool == 'bash') return (input['command'] as String?) ?? '';
    return (input['filePath'] as String?) ?? '';
  }

  /// The pattern that "always" should remember — broader than the exact
  /// call so one approval covers a directory of edits or a family of
  /// commands instead of every single one.
  static String defaultAlwaysPatternFor(
      String tool, Map<String, dynamic> input) {
    if (tool == 'bash') {
      final cmd = ((input['command'] as String?) ?? '').trim();
      if (cmd.isEmpty) return '*';
      final firstWord = cmd.split(RegExp(r'\s+')).first;
      return '$firstWord *';
    }
    final path = (input['filePath'] as String?) ?? '';
    if (path.isEmpty) return '*';
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return '*';
    return '${path.substring(0, lastSlash)}/*';
  }

  /// Wire shape for persistence. Captures [defaults] (tool -> decision) and
  /// the static (CLI) rules. [sessionRules] (runtime "remember this" memory) are
  /// intentionally NOT persisted — reconstructing them from disk is a follow-up.
  Map<String, dynamic> toJson() => {
        'defaults': {
          for (final e in defaults.entries) e.key: e.value.name,
        },
        'staticRules': staticRules.map((r) => r.toJson()).toList(),
      };

  factory PermissionPolicy.fromJson(Map<String, dynamic> j) => PermissionPolicy(
        defaults: {
          for (final e in (j['defaults'] as Map).entries)
            e.key as String:
                PermissionDecision.values.byName(e.value as String),
        },
        rules: (j['staticRules'] as List? ?? const [])
            .map((e) =>
                PermissionRule.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static bool _appliesTo(PermissionRule r, String tool, String key) {
    if (r.toolName != '*' && r.toolName != tool) return false;
    // Bash patterns operate on command strings, not paths — `*` there should
    // span arbitrary chars including `/` (`rm *` covers `rm -rf /tmp`). For
    // file tools we keep the usual shell distinction: `*` stops at `/`, `**`
    // crosses directory boundaries.
    return globMatch(r.pattern, key, starMatchesSlash: tool == 'bash');
  }
}

/// Tiny shell-style glob matcher. With `starMatchesSlash: false` (the
/// default), `*` matches any chars except `/` while `**` matches anything;
/// with it true (used for bash command patterns) `*` matches anything.
/// Other regex metachars are escaped.
bool globMatch(String pattern, String input,
    {bool starMatchesSlash = false}) {
  final sb = StringBuffer(r'^');
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        sb.write('.*');
        i++;
      } else {
        sb.write(starMatchesSlash ? '.*' : '[^/]*');
      }
    } else if (r'.+?^$(){}[]|\'.contains(c)) {
      sb.write('\\$c');
    } else {
      sb.write(c);
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString()).hasMatch(input);
}

PermissionRule parsePermissionRule(String spec, PermissionDecision decision) {
  final idx = spec.indexOf(':');
  if (idx <= 0 || idx == spec.length - 1) {
    throw FormatException(
        'Permission rule must be TOOL:PATTERN, got: "$spec"');
  }
  return PermissionRule(
    toolName: spec.substring(0, idx),
    pattern: spec.substring(idx + 1),
    decision: decision,
  );
}

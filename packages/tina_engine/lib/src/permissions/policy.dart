enum PermissionDecision { allow, deny, ask }

/// Session-wide permission mode, layered on top of the per-tool defaults.
///
/// - [ask]: the built-in defaults — read-only tools run, mutating tools prompt.
/// - [readAll]: every read-only tool (including network reads) runs without
///   prompting; writes still prompt.
/// - [allowEdits]: reads plus `write`/`edit` run; `bash` still prompts.
/// - [auto]: gate level identical to [ask], but the asker is an LLM
///   classifier that decides each call (see `modeAwareAsker`) — falling back
///   to the interactive prompt when the classifier errors or times out.
enum PermissionMode { ask, readAll, allowEdits, auto }

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

  /// Current mode. Mutable so `/permissions <mode>` can switch at runtime;
  /// consulted by [check] on every call, so a change applies immediately to
  /// agents already holding this policy.
  PermissionMode mode;

  PermissionPolicy({
    Map<String, PermissionDecision>? defaults,
    List<PermissionRule>? rules,
    this.mode = PermissionMode.ask,
  })  : defaults = Map.from(defaults ?? _builtinDefaults),
        staticRules = List.unmodifiable(rules ?? const []);

  static const _builtinDefaults = {
    'read': PermissionDecision.allow,
    'write': PermissionDecision.ask,
    'edit': PermissionDecision.ask,
    'bash': PermissionDecision.ask,
    // Read-only tools never mutate anything, so they run without prompting.
    // Users can still deny any of them via a session/static rule.
    'search': PermissionDecision.allow,
    'grep': PermissionDecision.allow,
    'glob': PermissionDecision.allow,
    'ls': PermissionDecision.allow,
    'stat': PermissionDecision.allow,
    'which': PermissionDecision.allow,
    // Network reads and the summary sidecar: gated by default (explicit here
    // rather than via the `?? ask` fallback, so /permissions lists them).
    'fetch': PermissionDecision.ask,
    'web_search': PermissionDecision.ask,
    'write_summary': PermissionDecision.allow,
    // The git tool's subcommand allowlist makes mutation impossible, so it
    // is read-only by construction (see GitTool).
    'git': PermissionDecision.allow,
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
    return _widen(tool, defaults[tool] ?? PermissionDecision.ask);
  }

  /// Tools that only ever read. [PermissionMode.readAll] and [allowEdits]
  /// auto-approve these; `_builtinDefaults` already allows most of them — the
  /// set additionally covers the network reads and region queries that gate
  /// by default.
  static const _readOnlyTools = {
    'read', 'search', 'grep', 'glob', 'ls', 'stat', 'which', 'git',
    'fetch', 'web_search', 'repo_structure', 'list_regions',
    'read_summary', 'query_region',
  };

  /// Widen a default decision according to [mode]. Session/static rules are
  /// unaffected — an explicit `--deny` still denies in every mode.
  PermissionDecision _widen(String tool, PermissionDecision d) {
    switch (mode) {
      case PermissionMode.ask:
      case PermissionMode.auto:
        return d;
      case PermissionMode.readAll:
        return _readOnlyTools.contains(tool) ? PermissionDecision.allow : d;
      case PermissionMode.allowEdits:
        return (_readOnlyTools.contains(tool) ||
                tool == 'write' ||
                tool == 'edit')
            ? PermissionDecision.allow
            : d;
    }
  }

  void remember(String tool, String pattern, PermissionDecision decision) {
    sessionRules.add(PermissionRule(
      toolName: tool,
      pattern: pattern,
      decision: decision,
    ));
  }

  /// The ALLOW patterns that exist for [tool] (static rules, then session
  /// rules, each as `tool:pattern`), for the remediation message a denied
  /// call carries back to the model. A wildcard-tool (`*`) rule counts for
  /// every tool; a rule remembered in the session that also exists statically
  /// is listed once.
  List<String> allowedPatterns(String tool) {
    final out = <String>[];
    for (final r in [...staticRules, ...sessionRules]) {
      if (r.decision != PermissionDecision.allow) continue;
      if (r.toolName != tool && r.toolName != '*') continue;
      final display = '$tool:${r.pattern}';
      if (!out.contains(display)) out.add(display);
    }
    return out;
  }

  /// What this tool call boils down to for matching / display purposes.
  /// For bash it's the command string; for file tools it's the file path; for
  /// `launch_workflow` it's the workflow name (the thing the call targets, and
  /// short enough for the approval line).
  static String keyFor(String tool, Map<String, dynamic> input) {
    if (tool == 'bash') return (input['command'] as String?) ?? '';
    if (tool == 'launch_workflow') {
      final name = (input['workflow'] as String?)?.trim();
      return (name == null || name.isEmpty) ? 'default' : name;
    }
    return (input['filePath'] as String?) ?? '';
  }

  /// The pattern that "always" should remember. For file tools this is broader
  /// than the exact call — the parent directory, so one approval covers a whole
  /// directory of edits. For **bash** it is the **exact command**: a permissive
  /// family-wide pattern (`<firstWord> *`) would let one `rm` approval silently
  /// cover `rm -rf .` for the rest of the session. The exact command has no
  /// unescaped `*`, so [globMatch] matches it literally; a command that
  /// genuinely contains a `*` stays a narrow glob rather than widening to the
  /// whole family.
  static String defaultAlwaysPatternFor(
      String tool, Map<String, dynamic> input) {
    if (tool == 'bash') {
      final cmd = ((input['command'] as String?) ?? '').trim();
      return cmd.isEmpty ? '*' : cmd;
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
        'mode': mode.name,
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
        mode: PermissionMode.values.byName(j['mode'] as String? ?? 'ask'),
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

import 'dart:convert';

import '../tools/execution_request.dart';
import 'approval_target.dart';

enum PermissionDecision { allow, deny, ask }

/// Session-wide permission mode, layered on top of the per-tool defaults.
///
/// - [ask]: the built-in defaults — read-only tools run, mutating tools prompt.
/// - [readAll]: read-only tools (including network reads) run without
///   prompting; shell, writes, and indirect execution are blocked.
/// - [allowEdits]: reads plus `write`/`edit` run; `bash` still prompts.
/// - [auto]: gate level identical to [ask], but the asker is an LLM
///   classifier that decides each call (see `modeAwareAsker`) — falling back
///   to the interactive prompt when the classifier errors or times out.
enum PermissionMode {
  ask,
  readAll,
  allowEdits,
  auto;

  /// Shift+Tab's ring: ask → readAll → allowEdits → auto → ask. Explicit
  /// rather than values-index arithmetic so a future insertion can't
  /// silently change the cycle order.
  PermissionMode get nextMode => switch (this) {
        ask => readAll,
        readAll => allowEdits,
        allowEdits => auto,
        auto => ask,
      };

  /// The CLI/TUI spelling (`--permission-mode`, `/permissions`, config
  /// files): dashed, not the enum's camelCase name.
  String get label => switch (this) {
        ask => 'ask',
        readAll => 'read-all',
        allowEdits => 'allow-edits',
        auto => 'auto',
      };
}

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

/// How long an approval lasts.
///
/// Every "always" answer names one of these, so the scope is a recorded fact
/// rather than something implied by which prompt happened to be on screen. The
/// four answers are the four scopes: a fix, a conversation, a project's shared
/// writable directories, and running outside the sandbox.
enum GrantScope {
  /// This call only.
  call,

  /// This conversation, until the process exits. Never written to disk.
  conversation,

  /// The project scope's writable directories, shared by its agents, for the
  /// running session.
  sessionDirectories,

  /// This exact invocation running outside the sandbox, for the running
  /// session, shared by related agents.
  sessionOutside;

  /// The scope in plain words, for the approval prompt and `/permissions`.
  String get plainWords => switch (this) {
        call => 'this call only',
        conversation => 'this conversation, until tina exits',
        sessionDirectories => "this project's agents, for this session",
        sessionOutside => 'this session, including its agents',
      };
}

/// Who answered an approval.
///
/// Recorded because a grant a model made and a grant a person made are the same
/// rule once remembered — and they must not be treated the same. See
/// [PermissionPolicy.check]: a classifier grant never overrides a rule a human
/// configured.
enum GrantSource { user, classifier }

/// One remembered decision: the rule, how long it lasts, and who made it.
class SessionGrant {
  final PermissionRule rule;
  final GrantScope scope;
  final GrantSource source;

  const SessionGrant({
    required this.rule,
    required this.scope,
    required this.source,
  });

  @override
  String toString() =>
      '${rule} (${scope.plainWords}, ${source == GrantSource.user ? 'you' : 'classifier'})';
}

class PermissionPolicy {
  final Map<String, PermissionDecision> defaults;
  final List<PermissionRule> staticRules;

  /// Remembered decisions, with their scope and who made them. In-memory only.
  final List<SessionGrant> sessionGrants = [];

  /// Just the rules, for callers that do not care who made them (the denial
  /// remediation text, `/permissions`' older shape). Reads the list, so the
  /// order matches [sessionGrants].
  List<PermissionRule> get sessionRules =>
      [for (final g in sessionGrants) g.rule];

  // Separate from wildcard command rules; never serialized. Derived policies
  // in the same running session share exact grants, but keep their deny gates.
  final _outsideSandboxGrants = <({String tool, ExecutionRequest request})>[];
  PermissionPolicy get _grantOwner => modeSource?._grantOwner ?? this;

  bool allowsOutsideSandbox(String tool, ExecutionRequest request) =>
      _grantOwner._outsideSandboxGrants.any((grant) =>
          grant.tool == tool && grant.request.sameInvocationAs(request));

  void rememberOutsideSandbox(String tool, ExecutionRequest request) {
    if (!allowsOutsideSandbox(tool, request)) {
      _grantOwner._outsideSandboxGrants.add((tool: tool, request: request));
    }
  }

  /// Current mode. Mutable so `/permissions <mode>` can switch at runtime;
  /// consulted by [check] on every call, so a change applies immediately to
  /// agents already holding this policy.
  PermissionMode _mode;

  /// Derived policies keep independent allow rules but share live mode state.
  final PermissionPolicy? modeSource;
  PermissionMode get mode => modeSource?.mode ?? _mode;
  set mode(PermissionMode value) {
    final source = modeSource;
    if (source == null) {
      _mode = value;
    } else {
      source.mode = value;
    }
  }

  /// `--yolo` posture: every tool's default becomes [PermissionDecision.allow]
  /// — including tools absent from [defaults] — without restating a tool
  /// list, so a tool added later cannot fall back to `ask`. Static rules,
  /// session rules, and [executionBlock] (e.g. read-all's hard boundary)
  /// still apply: an explicit `--deny` denies, and read-all still blocks
  /// mutating tools.
  final bool allowAllByDefault;

  PermissionPolicy({
    Map<String, PermissionDecision>? defaults,
    List<PermissionRule>? rules,
    PermissionMode mode = PermissionMode.ask,
    this.modeSource,
    this.allowAllByDefault = false,
  })  : _mode = mode,
        defaults = Map.from(defaults ?? _builtinDefaults),
        staticRules = List.unmodifiable(rules ?? const []);

  static const _builtinDefaults = {
    'read': PermissionDecision.allow,
    'write': PermissionDecision.ask,
    'edit': PermissionDecision.ask,
    'bash': PermissionDecision.ask,
    'exec': PermissionDecision.ask,
    'execution_info': PermissionDecision.allow,
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
    if (executionBlock(tool, input) != null) return PermissionDecision.deny;
    final target = targetFor(tool, input);
    // What a human configured for this call, if anything. First match wins, as
    // it always has.
    PermissionDecision? configured;
    for (final r in staticRules) {
      if (_appliesTo(r, tool, target)) {
        configured = r.decision;
        break;
      }
    }
    // Session memory wins over the configured rules and over the defaults;
    // latest decision wins within it. The exception is a classifier's grant: it
    // answers in place of the user, not above them, so it never overrides a rule
    // a human wrote.
    for (final g in sessionGrants.reversed) {
      if (g.source == GrantSource.classifier && configured != null) continue;
      if (_appliesTo(g.rule, tool, target)) return g.rule.decision;
    }
    if (configured != null) return configured;
    // `--yolo` widens EVERY default to allow — the table's own ask entries
    // and the unmapped-tool fallback alike — so a tool added later cannot
    // fall back to ask. The table is not rewritten, so rule precedence and
    // the mode gate below behave exactly as they do without the flag, and a
    // policy copy (sub-agent, workflow run) that spreads this table in keeps
    // the posture through its own flag.
    final fallback = allowAllByDefault
        ? PermissionDecision.allow
        : defaults[tool] ?? PermissionDecision.ask;
    return _widen(tool, fallback);
  }

  /// Hard mode boundary, evaluated before remembered/static allows and again
  /// immediately before execution. It never opens an approval prompt.
  String? executionBlock(String tool, Map<String, dynamic> input) {
    if (mode != PermissionMode.readAll) return null;
    if (tool == 'delegate') {
      final delegations = input['delegations'];
      if (delegations is List &&
          delegations
              .any((entry) => entry is Map && entry['tools'] == 'full')) {
        return 'Full-access delegation is disabled in read-all (read-only) mode. Use read-only scouts.';
      }
      return null;
    }
    if (_readOnlyTools.contains(tool) ||
        const {
          'broadcast_region',
          'receive',
          'close',
          'ask_user',
          'stop_workflow',
          'render_image',
        }.contains(tool)) return null;
    return '$tool is disabled in read-all (read-only) mode. '
        'Use read, grep, search, ls, glob, stat, which, or read-only git. '
        'Do not retry through bash or another agent. The user must switch '
        'to an execution-capable mode before setup, builds, tests, or writes.';
  }

  /// Tools that only ever read. [PermissionMode.readAll] and [allowEdits]
  /// auto-approve these; `_builtinDefaults` already allows most of them — the
  /// set additionally covers the network reads and region queries that gate
  /// by default.
  static const _readOnlyTools = {
    'execution_info', 'read', 'search', 'grep', 'glob', 'ls', 'stat', 'which', 'git',
    'fetch', 'web_search', 'repo_structure', 'list_regions',
    'read_summary', 'query_region', 'explore_project',
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

  void remember(
    String tool,
    String pattern,
    PermissionDecision decision, {
    GrantScope scope = GrantScope.conversation,
    GrantSource source = GrantSource.user,
  }) {
    sessionGrants.add(SessionGrant(
      rule: PermissionRule(
        toolName: tool,
        pattern: pattern,
        decision: decision,
      ),
      scope: scope,
      source: source,
    ));
  }

  /// Drop remembered decisions and return how many went.
  ///
  /// With no arguments, all of them. [tool] (and optionally [pattern]) narrows
  /// it, so `/permissions revoke bash:git status` takes back one answer without
  /// disturbing the rest. Configured rules are untouched — this only forgets
  /// what was remembered at a prompt.
  int forget({String? tool, String? pattern}) {
    final before = sessionGrants.length;
    sessionGrants.removeWhere((g) =>
        (tool == null || g.rule.toolName == tool) &&
        (pattern == null || g.rule.pattern == pattern));
    return before - sessionGrants.length;
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

  /// Static rules that name a tool which is not mounted, so they can never
  /// match anything. A rule for an unknown tool is silently inert — a typo in
  /// `--deny 'bashh:rm *'`, or a rule for a plugin tool this project does not
  /// expose. The caller reports these once at startup so the mistake is
  /// visible instead of quietly doing nothing.
  ///
  /// A `*` rule is never reported: it is meant to cover every tool, mounted or
  /// not.
  List<PermissionRule> inertRules(Iterable<String> mountedTools) {
    final mounted = mountedTools.toSet();
    return [
      for (final r in staticRules)
        if (r.toolName != '*' && !mounted.contains(r.toolName)) r,
    ];
  }

  /// What one call is asking permission for: the label the prompt shows, the
  /// rule an "always" answer remembers, and the glob semantics a configured rule
  /// matches with.
  ///
  /// One chain for every tool, because the prompt, the remembered rule and the
  /// CLI rule must agree — they are all read off this. Tools are migrated onto
  /// it as they are audited; an unmigrated tool falls through to the file-path
  /// case, which produces [ApprovalTarget.unknown] for an input with nothing to
  /// point at (the registry sweep fails such a tool the moment it can prompt).
  static ApprovalTarget targetFor(String tool, Map<String, dynamic> input) {
    switch (tool) {
      case 'exec':
        return ApprovalTarget.invocation(
            _invocationKey(input, commandKey: 'executable', includeArgs: true));
      case 'bash':
        if (input.containsKey('environment')) {
          // A custom environment is part of what was authorized: the same
          // command under a different environment is a different call.
          return ApprovalTarget.invocation(_invocationKey(input,
              commandKey: 'command', includeArgs: false));
        }
        // The EXACT command, not `firstWord *`: one `rm` approval must not
        // silently cover `rm -rf .` for the rest of the conversation.
        return ApprovalTarget.exact(
            ((input['command'] as String?) ?? '').trim());
      case 'launch_workflow':
        // The workflow name, NOT the wildcard: approving one workflow must not
        // approve every workflow.
        final name = (input['workflow'] as String?)?.trim();
        return ApprovalTarget.exact(
            (name == null || name.isEmpty) ? 'default' : name);
      case 'fetch':
        // The url — which is also the thing the user is approving, so the
        // prompt names it instead of showing an empty target.
        return ApprovalTarget.url((input['url'] as String?) ?? '');
      case 'web_search':
        return ApprovalTarget.exact((input['query'] as String?) ?? '');
      case 'broadcast_region':
        return ApprovalTarget.exact((input['task'] as String?) ?? '');
      case 'forget_region':
        // A region name, not a path: remember exactly the region.
        return ApprovalTarget.exact((input['dir'] as String?) ?? '');
      default:
        return ApprovalTarget.path((input['filePath'] as String?) ?? '');
    }
  }

  /// The serialized invocation `exec` and env-carrying `bash` calls key on.
  ///
  /// The two shapes are kept exactly as they were — exec carries its argument
  /// list, bash does not — so an existing rule keeps matching the call it was
  /// written for.
  static String _invocationKey(
    Map<String, dynamic> input, {
    required String commandKey,
    required bool includeArgs,
  }) {
    final raw = input['environment'];
    final env = raw is Map ? raw : const <String, dynamic>{};
    final keys = env.keys.cast<String>().toList()..sort();
    return jsonEncode([
      input[commandKey],
      if (includeArgs) input['args'] ?? [],
      input['cwd'],
      {for (final key in keys) key: env[key]},
    ]);
  }

  /// What this call boils down to for matching / display purposes. See
  /// [targetFor], which this reads from.
  static String keyFor(String tool, Map<String, dynamic> input) =>
      targetFor(tool, input).label;

  /// The pattern that "always" should remember. See [targetFor]. For file tools
  /// this is broader than the exact call — the parent directory, so one approval
  /// covers a whole directory of edits. For **bash** it is the **exact command**:
  /// a family-wide pattern (`<firstWord> *`) would let one `rm` approval silently
  /// cover `rm -rf .` for the rest of the session. An exact command has no
  /// unescaped `*`, so [globMatch] matches it literally; a command that genuinely
  /// contains a `*` stays a narrow glob rather than widening to the whole family.
  static String defaultAlwaysPatternFor(
          String tool, Map<String, dynamic> input) =>
      targetFor(tool, input).remember;

  /// Wire shape for persistence. Captures [defaults] (tool -> decision), the
  /// static (CLI) rules, and the yolo posture. [sessionRules] (runtime
  /// "remember this" memory) are intentionally NOT persisted — reconstructing
  /// them from disk is a follow-up.
  Map<String, dynamic> toJson() => {
        'defaults': {
          for (final e in defaults.entries) e.key: e.value.name,
        },
        'staticRules': staticRules.map((r) => r.toJson()).toList(),
        'mode': mode.name,
        if (allowAllByDefault) 'allowAllByDefault': true,
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
        allowAllByDefault: j['allowAllByDefault'] as bool? ?? false,
      );

  static bool _appliesTo(PermissionRule r, String tool, ApprovalTarget target) {
    if (r.toolName != '*' && r.toolName != tool) return false;
    // A rule that is itself a serialized invocation is compared exactly, never
    // globbed — `[` and `]` are glob metacharacters.
    if (target.invocation && r.pattern.startsWith('[')) {
      return r.pattern == target.label;
    }
    // Whether `*` spans `/` is the target's call, not the tool's: commands and
    // urls are full of slashes and want it to, paths keep the shell rule where
    // `**` is what crosses directories.
    return globMatch(r.pattern, target.label,
        starMatchesSlash: target.starMatchesSlash);
  }
}

/// Tiny shell-style glob matcher. With `starMatchesSlash: false` (the
/// default), `*` matches any chars except `/` while `**` matches anything; with
/// it true `*` matches anything too. Which one applies is the
/// [ApprovalTarget]'s decision, not the tool's.
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

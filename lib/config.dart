import 'dart:io';

import 'package:args/args.dart';
import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

import 'config/user_config.dart';
import 'project/project_trust.dart';

/// Built-in model tiers, seeded into [Config.modelTiers] so a sub-agent role
/// with a `modelTier` (e.g. scout/tester → `'light'`) resolves out of the box
/// instead of throwing `unknown model tier`. A `[tiers]` table in the user
/// config overrides per key. Both are anthropic — the default provider — and
/// resolve through the prefixed `"provider/model"` path, so the model ids are
/// forwarded on the wire as-is regardless of catalog membership.
const _defaultModelTiers = <String, String>{
  'heavy': 'anthropic/claude-sonnet-4-6',
  'light': 'anthropic/claude-haiku-4-5',
};

/// Which rendering backend to use. [BackendChoice.notcurses] is the default and
/// is required — it fails loudly if notcurses can't initialize. Only
/// [BackendChoice.ansi] uses the ANSI renderer (opt in via `--backend ansi`).
enum BackendChoice { ansi, notcurses }

class Config {
  /// Registry provider id, e.g. "anthropic", "openai", "glm".
  final String provider;
  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final bool yolo;
  final bool showHelp;
  final String? prompt;
  final List<PermissionRule> permissionRules;

  /// Persistence options.
  final String? resumeSessionId;
  final bool continueLatest;
  final bool listSessions;

  /// Token budgets — 0 means "no cap".
  final int maxTurnTokens;
  final int maxSessionTokens;
  final int maxRequestTokens;

  /// Global spend / rate-limit guardrails. One session-scoped ledger covers
  /// every agent (main + orchestrator + all scouts). 0 in any field means "no
  /// limit" for that field.
  final int maxGlobalTokens;
  final int maxSubAgentTokens;
  final int maxSubAgentDepth;
  final int maxSubAgentConcurrency;
  final int requestsPerMinute;

  /// Auto-compact: summarize the older history when an incoming turn's
  /// estimated input tokens exceed this, keeping recent turns. 0 disables.
  final int autoCompactThreshold;

  /// Hard cap on tool-calling steps per user turn. Catches a model that
  /// keeps invoking tools without converging on an answer.
  final int maxSteps;

  /// How long an SSE stream may be silent before we treat it as dead.
  /// Generous default so a slow completion doesn't fail spuriously.
  final Duration streamIdleTimeout;

  /// How long to wait for response headers on a single HTTP attempt (LLM
  /// requests). Threaded through to [sendWithRetry]. Distinct from
  /// [streamIdleTimeout], which covers silence *during* the SSE stream.
  final Duration requestTimeout;

  /// Which rendering backend to use. [BackendChoice.notcurses] is the default
  /// and is required; [BackendChoice.ansi] forces the ANSI renderer. Set from
  /// `--backend`.
  final BackendChoice backend;

  /// Verbose logging (`--verbose` / `-v`, or `COCOON_DEBUG=1`). Selects
  /// `Level.FINE` at logging init so swallowed-exception and lifecycle records
  /// are captured.
  final bool verbose;

  /// Write a commented TOML template to `~/.tina/config` (chmod 600) and exit
  /// (`--init-config`). Lets a new user bootstrap the persistent config.
  final bool initConfig;

  /// Force the first-run setup overlay (`--setup`), even when the app is already
  /// configured. Also fires automatically when no key resolves for the default
  /// provider. Stored on [Config] so `main` can read it post-parse.
  final bool setup;

  /// `tier → "provider/model"` map for sub-agent model selection. Seeded with
  /// [_defaultModelTiers] (heavy + light anthropic) so a role with `modelTier:
  /// 'light'` (e.g. scout, tester) resolves out of the box; a `[tiers]` table in
  /// the user config overrides per key.
  final Map<String, String> modelTiers;

  /// `role → identity` system-prompt overrides from the `[prompts.<role>]`
  /// config table. An absent role means "use the built-in default identity".
  /// Threaded into the agent catalog so each role's resolver checks here first.
  /// Empty by default.
  final Map<String, String> promptOverrides;

  /// Terminal color theme; carried through to the TUI's [Screen].
  final Theme theme;

  /// Read-only session (`--safe-mode`): `write`/`edit`/`bash` are removed from
  /// every agent and each is told it may only read. Inherently `--yolo`-proof
  /// (yolo only relaxes the ask-gate; the tools simply don't exist). Defaults
  /// off, so the `--help`/`--init-config`/`--list` short-circuits need no change.
  final bool safeMode;

  /// `--trust` / `--no-trust`: an explicit override of the project-trust gate.
  /// Null (the default) means "use the normal ask/skip/default logic" in
  /// `resolveProjectTrust`. `true` forces loading AGENTS.md; `false` withholds
  /// it. Useful for CI / known-good / known-bad directories.
  final bool? trustOverride;

  /// Default trust behavior from `[trust] default` in ~/.tina/config
  /// (`ask`/`always`/`never`). `ask` (the default) prompts in the TUI and skips
  /// AGENTS.md headless.
  final TrustDefault trustDefault;

  const Config({
    required this.provider,
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    required this.maxTokens,
    required this.yolo,
    required this.showHelp,
    required this.prompt,
    required this.permissionRules,
    required this.resumeSessionId,
    required this.continueLatest,
    required this.listSessions,
    required this.maxTurnTokens,
    required this.maxSessionTokens,
    required this.maxRequestTokens,
    required this.maxGlobalTokens,
    required this.maxSubAgentTokens,
    required this.maxSubAgentDepth,
    required this.maxSubAgentConcurrency,
    required this.requestsPerMinute,
    required this.autoCompactThreshold,
    required this.maxSteps,
    required this.streamIdleTimeout,
    required this.requestTimeout,
    required this.backend,
    required this.verbose,
    required this.initConfig,
    required this.setup,
    required this.modelTiers,
    this.promptOverrides = const {},
    this.theme = const Theme.defaults(),
    this.safeMode = false,
    this.trustOverride,
    this.trustDefault = TrustDefault.ask,
  });

  bool get nonInteractive => prompt != null;

  static final _parser = ArgParser()
    ..addOption('base-url')
    ..addOption('max-tokens', defaultsTo: '8192')
    ..addOption('prompt',
        help: 'Run a single prompt non-interactively and exit.')
    ..addMultiOption('allow',
        help: 'Allow rule: TOOL:PATTERN, e.g. --allow "bash:git *" '
            '--allow "read:/workspace/**". Can be repeated.')
    ..addMultiOption('deny',
        help: 'Deny rule: same syntax as --allow. Deny rules take '
            'precedence over allow rules of the same scope.')
    ..addFlag('yolo',
        negatable: false,
        help:
            'Default every tool to allow (skip all permission prompts). '
            'Explicit --deny rules still apply.')
    ..addFlag('safe-mode',
        negatable: false,
        help:
            'Read-only session: remove write/edit/bash from every agent and '
            'instruct each it may only read. Inherently --yolo-proof — safe-'
            'mode silently dominates --yolo.')
    ..addOption('resume',
        help: 'Resume a saved session by id. See /sessions inside the REPL.')
    ..addFlag('continue',
        abbr: 'c',
        negatable: false,
        help: 'Resume the most recently updated session.')
    ..addFlag('list',
        abbr: 'l',
        negatable: false,
        help: 'List saved sessions and exit.')
    ..addOption('max-turn-tokens',
        defaultsTo: '1000000',
        help: 'Abort a user turn if input+output exceeds this many tokens. '
            'Guard against runaway tool loops. 0 to disable.')
    ..addOption('max-session-tokens',
        defaultsTo: '10000000',
        help: 'Abort if cumulative session tokens exceed this. '
            'Resets on /clear. 0 to disable.')
    ..addOption('max-request-tokens',
        defaultsTo: '200000',
        help: 'Refuse to send a request whose input alone exceeds this '
            '(approx). 0 to disable.')
    ..addOption('max-global-tokens',
        defaultsTo: '0',
        help: 'Hard cap on total tokens across ALL agents this app session '
            '(main + orchestrator + scouts). Trips a hard abort when crossed. '
            '0 falls back to the file default, or unbounded if neither is set.')
    ..addOption('max-sub-agent-tokens',
        defaultsTo: '0',
        help: 'Per-session token cap for each sub-agent (they otherwise run '
            'uncapped). 0 falls back to the file default, or unbounded.')
    ..addOption('max-sub-agent-depth',
        defaultsTo: '3',
        help: 'Maximum nesting depth for sub-agent delegation — the root '
            'orchestrator is depth 0, its direct children are depth 0, and so '
            'on. A spawn at this depth or deeper is rejected. Overrides the '
            '[limits] max_sub_agent_depth key.')
    ..addOption('max-sub-agent-concurrency',
        defaultsTo: '6',
        help: 'Maximum number of sub-agents allowed to run concurrently. '
            'Extra spawns queue until a slot frees. Overrides the [limits] '
            'max_sub_agent_concurrency key.')
    ..addOption('requests-per-minute',
        defaultsTo: '0',
        help: 'Global requests-per-minute throttle shared by all agents. '
            '0 disables it (or falls back to the file default).')
    ..addOption('auto-compact-threshold',
        defaultsTo: '120000',
        help: 'Auto-summarize older history when an incoming turn\'s estimated '
            'input tokens exceed this, keeping recent turns. 0 disables.')
    ..addOption('max-steps',
        defaultsTo: '50',
        help: 'Maximum tool-calling steps allowed in a single user turn.')
    ..addOption('stream-idle-timeout',
        defaultsTo: '60',
        help: 'Seconds to wait between SSE events before declaring the '
            'stream dead. Bump for very slow models.')
    ..addOption('request-timeout',
        defaultsTo: '30',
        help: 'Seconds to wait for response headers per attempt before '
            'aborting the request. Slow providers or large-context prompts '
            'may need more than the 30s default.')
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('verbose',
        abbr: 'v',
        negatable: false,
        help: 'Verbose logging (Level.FINE). Equivalent to COCOON_DEBUG=1; '
            'captures swallowed-exception and lifecycle records in '
            '~/.tina/tina.log.')
    ..addFlag('init-config',
        negatable: false,
        help: 'Write a commented TOML template to ~/.tina/config (chmod 600) '
            'and exit. Edits there persist provider, model, tiers, and API '
            'keys so you can stop passing them on the CLI / as env vars.')
    ..addFlag('setup',
        negatable: false,
        help: 'Run the interactive first-run setup wizard (provider/model per '
            'tier). Also runs automatically when no config exists and stdin is '
            'a terminal.')
    ..addOption('backend',
        allowed: ['ansi', 'notcurses'],
        defaultsTo: 'notcurses',
        help: 'Rendering backend. "notcurses" (the default) forces notcurses '
            'and exits if it cannot initialize; "ansi" forces the ANSI '
            'renderer.')
    ..addFlag('trust',
        negatable: true,
        help: 'Override the project-trust gate. --trust loads this '
            'directory\'s AGENTS.md without asking; --no-trust withholds it. '
            'By default tina asks (TUI) or skips (headless) for an untrusted '
            'project. See [trust] default in ~/.tina/config.');

  static String get usage => 'tina — terminal coding agent\n\n${_parser.usage}';

  /// Placeholder [Config] for the `--help` / `--init-config` / `--list`
  /// short-circuits. Each of those runs before provider/key resolution (so it
  /// works on a fresh install) and main() reads only the one flag set here
  /// before exiting — none of the parser's real defaults matter. Exactly one of
  /// [showHelp] / [initConfig] / [listSessions] is true per call.
  static Config _shortCircuitConfig({
    bool showHelp = false,
    bool initConfig = false,
    bool listSessions = false,
  }) =>
      Config(
        provider: 'anthropic',
        apiKey: '',
        model: '',
        baseUrl: '',
        maxTokens: 0,
        yolo: false,
        showHelp: showHelp,
        prompt: null,
        permissionRules: const [],
        resumeSessionId: null,
        continueLatest: false,
        listSessions: listSessions,
        maxTurnTokens: 0,
        maxSessionTokens: 0,
        maxRequestTokens: 0,
        maxGlobalTokens: 0,
        maxSubAgentTokens: 0,
        maxSubAgentDepth: 3,
        maxSubAgentConcurrency: 6,
        requestsPerMinute: 0,
        autoCompactThreshold: 0,
        maxSteps: 50,
        streamIdleTimeout: const Duration(seconds: 60),
        requestTimeout: const Duration(seconds: 30),
        backend: BackendChoice.notcurses,
        verbose: false,
        initConfig: initConfig,
        setup: false,
        modelTiers: const <String, String>{},
        trustOverride: null,
        trustDefault: TrustDefault.ask,
      );

  factory Config.parse(List<String> argv,
      {Map<String, String>? env,
      ProviderRegistry? registry,
      UserConfig? userConfig}) {
    final res = _parser.parse(argv);
    // --help / --init-config / --list short-circuit before provider/key
    // resolution: each runs on a fresh install with no credentials, so none of
    // the parser's real defaults (token budgets, auto-compact, etc.) matter —
    // main() reads only the short-circuit flag and exits. The three share one
    // placeholder Config that differs solely in which flag is set.
    if (res['help'] as bool) return _shortCircuitConfig(showHelp: true);

    // --init-config: main() writes a commented TOML template and exits.
    if (res['init-config'] as bool) return _shortCircuitConfig(initConfig: true);

    // --list: main() prints saved sessions and exits — only the on-disk store
    // is needed, not credentials.
    if (res['list'] as bool) return _shortCircuitConfig(listSessions: true);

    registry ??= builtinRegistry();
    env ??= Platform.environment;

    // Provider precedence: config file > 'anthropic' default.
    final providerId = userConfig?.defaultProvider ?? 'anthropic';
    final desc = registry.descriptor(providerId);
    if (desc == null) {
      throw FormatException('Unknown provider "$providerId". '
          'Known: ${registry.providerIds.join(', ')}');
    }

    // Resolve the API key via the registry's resolver — the SAME path
    // ProviderRegistry.build uses — so there's a single source of truth for the
    // env-var priority scan rather than two copies that can drift. We pass our
    // own `env` (the registry may have been constructed with a different one
    // when a caller injects it). The matching AuthScheme is carried through to
    // the provider builder at build time, so Anthropic sends Bearer for
    // ANTHROPIC_AUTH_TOKEN and x-api-key for ANTHROPIC_API_KEY without Config
    // knowing either.
    // The API key may resolve to '' (no env/config key yet). We deliberately do
    // NOT throw here: an unconfigured app boots into first-run setup rather than
    // exit(64). main() treats an empty key as "not configured" and shows the
    // setup overlay; the key only matters when a turn is actually sent.
    final apiKey = registry.authFor(desc, env: env).key;

    // Per-provider env overrides by convention: <PROVIDER>_MODEL / _BASE_URL.
    final envPrefix = providerId.toUpperCase();
    final defaultModel = env['${envPrefix}_MODEL'] ??
        (desc.models.isNotEmpty ? desc.models.keys.first : '');
    final defaultBaseUrl = env['${envPrefix}_BASE_URL'] ?? desc.defaultBaseUrl;

    final maxTokens = int.tryParse(res['max-tokens'] as String) ?? 8192;

    // Deny rules first so they win same-pattern ties.
    final rules = <PermissionRule>[
      for (final s in res['deny'] as List<String>)
        parsePermissionRule(s, PermissionDecision.deny),
      for (final s in res['allow'] as List<String>)
        parsePermissionRule(s, PermissionDecision.allow),
    ];

    // Model tiers: built-in defaults (heavy + light anthropic) so a role with
    // modelTier 'light' (scout, tester) resolves out of the box; a `[tiers]`
    // table in the user config overrides per key (file wins). See
    // [_defaultModelTiers].
    final modelTiers = <String, String>{
      ..._defaultModelTiers,
      ...?userConfig?.tiers,
    };

    final resumeId = res['resume'] as String?;
    final continueLatest = res['continue'] as bool;
    if (resumeId != null && continueLatest) {
      throw const FormatException(
          '--resume and --continue are mutually exclusive.');
    }

    int parseBudget(String name, String defaultValue) {
      final raw = (res[name] as String?) ?? defaultValue;
      final n = int.tryParse(raw);
      if (n == null || n < 0) {
        throw FormatException('--$name must be a non-negative integer; got "$raw"');
      }
      return n;
    }

    int parsePositive(String name, String defaultValue) {
      final raw = (res[name] as String?) ?? defaultValue;
      final n = int.tryParse(raw);
      if (n == null || n <= 0) {
        throw FormatException('--$name must be a positive integer; got "$raw"');
      }
      return n;
    }

    // Resolve a `[limits]` scalar with CLI > file > built-in-default precedence.
    // The default lives HERE (not in defaultsTo, which is '0') so res.wasParsed
    // cleanly separates a real CLI value from the ArgParser fallback. A file
    // value of 0 is honored (explicit "unbounded"); only an absent file value
    // (null) falls through to [defaultValue].
    int parseLimit(String name, int? fileValue, int defaultValue) {
      if (res.wasParsed(name)) {
        final raw = res[name] as String;
        final n = int.tryParse(raw);
        if (n == null || n < 0) {
          throw FormatException(
              '--$name must be a non-negative integer; got "$raw"');
        }
        return n;
      }
      return fileValue ?? defaultValue;
    }

    final fileLimits = userConfig?.limits;

    return Config(
      provider: providerId,
      apiKey: apiKey,
      model: userConfig?.defaultModel ?? defaultModel,
      baseUrl: (res['base-url'] as String?) ?? defaultBaseUrl,
      maxTokens: maxTokens,
      yolo: res['yolo'] as bool,
      showHelp: false,
      prompt: res['prompt'] as String?,
      permissionRules: rules,
      resumeSessionId: resumeId,
      continueLatest: continueLatest,
      listSessions: false,
      maxTurnTokens:
          parseLimit('max-turn-tokens', fileLimits?.maxTurnTokens, 1000000),
      maxSessionTokens: parseLimit(
          'max-session-tokens', fileLimits?.maxSessionTokens, 10000000),
      maxRequestTokens: parseLimit(
          'max-request-tokens', fileLimits?.maxRequestTokens, 200000),
      maxGlobalTokens:
          parseLimit('max-global-tokens', fileLimits?.maxGlobalTokens, 50000000),
      maxSubAgentTokens: parseLimit(
          'max-sub-agent-tokens', fileLimits?.maxSubAgentTokens, 2000000),
      maxSubAgentDepth:
          parseLimit('max-sub-agent-depth', fileLimits?.maxSubAgentDepth, 3),
      maxSubAgentConcurrency: parseLimit('max-sub-agent-concurrency',
          fileLimits?.maxSubAgentConcurrency, 6),
      requestsPerMinute: parseLimit(
          'requests-per-minute', fileLimits?.requestsPerMinute, 0),
      autoCompactThreshold: parseBudget('auto-compact-threshold', '120000'),
      maxSteps: parsePositive('max-steps', '50'),
      streamIdleTimeout:
          Duration(seconds: parsePositive('stream-idle-timeout', '60')),
      requestTimeout:
          Duration(seconds: parsePositive('request-timeout', '30')),
      backend: switch (res['backend'] as String) {
        'ansi' => BackendChoice.ansi,
        _ => BackendChoice.notcurses,
      },
      verbose: res['verbose'] as bool,
      initConfig: res['init-config'] as bool,
      setup: res['setup'] as bool,
      modelTiers: modelTiers,
      promptOverrides: userConfig?.prompts ?? const {},
      theme: _resolveTheme(userConfig),
      safeMode: res['safe-mode'] as bool,
      trustOverride:
          res.wasParsed('trust') ? res['trust'] as bool : null,
      trustDefault: _parseTrustDefault(userConfig?.trustDefault),
    );
  }

  /// Build a token budget from the parsed flags. 0 in any field disables
  /// that particular cap; if all three are 0 the budget is itself null.
  TokenBudget? buildTokenBudget() {
    if (maxTurnTokens == 0 &&
        maxSessionTokens == 0 &&
        maxRequestTokens == 0) {
      return null;
    }
    return TokenBudget(
      perTurnLimit: maxTurnTokens == 0 ? null : maxTurnTokens,
      perSessionLimit: maxSessionTokens == 0 ? null : maxSessionTokens,
      perRequestInputLimit: maxRequestTokens == 0 ? null : maxRequestTokens,
    );
  }

  /// Build the per-session token budget applied to each sub-agent (orchestrator
  /// / scouts / delegated work). Sub-agents otherwise run uncapped. null when
  /// [maxSubAgentTokens] is 0 (no limit), matching [buildTokenBudget]'s null-when-
  /// disabled convention.
  TokenBudget? buildSubAgentBudget() {
    if (maxSubAgentTokens == 0) return null;
    return TokenBudget(perSessionLimit: maxSubAgentTokens);
  }

  /// Build a policy from the parsed config. `--yolo` makes every default
  /// `allow`; CLI rules layer on top (so `--yolo --deny 'bash:rm *'` works).
  PermissionPolicy buildPolicy() {
    final defaults = yolo
        ? {
            'read': PermissionDecision.allow,
            'write': PermissionDecision.allow,
            'edit': PermissionDecision.allow,
            'bash': PermissionDecision.allow,
          }
        : null;
    return PermissionPolicy(defaults: defaults, rules: permissionRules);
  }
}

/// Resolve the user's [Theme] from [UserConfig], applying the `variant` key
/// when no explicit per-key overrides are set.
///
/// Priority: explicit per-key [Theme] overrides > named variant > shipped defaults.
Theme _resolveTheme(UserConfig? uc) {
  if (uc?.theme != null) return uc!.theme!;
  if (uc?.themeVariant != null) {
    return switch (uc!.themeVariant) {
      'light' => const Theme.light(),
      'dark' => const Theme.dark(),
      _ => const Theme.defaults(),
    };
  }
  return const Theme.defaults();
}

/// Parse `[trust] default` from the config file into a [TrustDefault]. Unknown
/// or absent → `ask`.
TrustDefault _parseTrustDefault(String? raw) => switch (raw) {
      'always' => TrustDefault.always,
      'never' => TrustDefault.never,
      _ => TrustDefault.ask,
    };

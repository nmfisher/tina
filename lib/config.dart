import 'dart:io';

import 'package:args/args.dart';
import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

import 'config/user_config.dart';
import 'package:tina_app/tina_app.dart';
import 'config/terminal_config.dart';
import 'config/resolved_launch.dart';
import 'config/theme_mapper.dart';

export 'package:tina_app/tina_app.dart'
    show ResumeRequest, RuntimeConfig, StartupOptions;
export 'config/terminal_config.dart';
export 'config/resolved_launch.dart';

// Default values for CLI flags and config options.
const int kDefaultMaxSteps = 500;
const int kDefaultWatchdogSeconds = 300;
const int kDefaultStreamIdleTimeoutSeconds = 180;
const int kDefaultRequestTimeoutSeconds = 120;
const int kDefaultTransportRetryAttempts = 5;
const int kDefaultMaxSubAgentConcurrency = 6;
const String kDefaultAutoCompactThreshold = '120000';

const _reasoningEfforts = [
  'auto',
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// Root compatibility facade. Application code consumes [runtime].
class Config extends RuntimeConfig implements ResumeRequest {
  /// Why the sandbox is off, when it is — `--no-sandbox` vs `--yolo` — so the
  /// TUI chip and the startup notice say who disabled it. Null when on.
  final String? sandboxOffReason;

  final bool showHelp;
  final String? models;
  final bool showVersion;
  final String? prompt;
  final String? resumeSessionId;
  final bool continueLatest;
  final bool listSessions;
  final bool resumePicker;
  final String? workflow;
  final BackendChoice backend;
  final bool verbose;
  final bool initConfig;
  final bool setup;
  final Theme theme;
  final bool? trustOverride;
  final TrustDefault trustDefault;
  final bool mouseWheel;
  final LayoutStyle layout;
  final bool forceLock;

  Config({
    required super.provider,
    required super.apiKey,
    required super.model,
    required super.baseUrl,
    required super.maxTokens,
    super.reasoningEffort,
    required super.yolo,
    required this.showHelp,
    this.showVersion = false,
    required this.prompt,
    required super.permissionRules,
    required this.resumeSessionId,
    required this.continueLatest,
    required this.listSessions,
    this.resumePicker = false,
    this.workflow,
    super.defaultWorkflow,
    required super.maxTurnTokens,
    required super.maxSessionTokens,
    required super.maxRequestTokens,
    required super.maxGlobalTokens,
    required super.maxSubAgentTokens,
    required super.maxSubAgentDepth,
    required super.maxSubAgentConcurrency,
    required super.requestsPerMinute,
    required super.autoCompactThreshold,
    required super.maxSteps,
    required super.watchdogSeconds,
    required super.streamIdleTimeout,
    required super.requestTimeout,
    required this.backend,
    required this.verbose,
    required this.initConfig,
    required this.setup,
    super.promptOverrides = const {},
    this.theme = const Theme.defaults(),
    super.safeMode = false,
    super.sandboxEnabled = true,
    this.sandboxOffReason,
    super.sandboxNet = false,
    super.sandboxReadOnly = false,
    this.trustOverride,
    this.trustDefault = TrustDefault.ask,
    this.mouseWheel = false,
    this.layout = LayoutStyle.tiled,
    super.regionsModel,
    super.permissionMode = PermissionMode.ask,
    super.permissionClassifierModel,
    super.modelExplicit = false,
    this.forceLock = false,
    super.transportRetryAttempts = 0,
    super.enableWorkflow = false,
    this.models,
  });

  RuntimeConfig get runtime => RuntimeConfig(
    provider: provider,
    apiKey: apiKey,
    model: model,
    baseUrl: baseUrl,
    maxTokens: maxTokens,
    reasoningEffort: reasoningEffort,
    yolo: yolo,
    permissionRules: permissionRules,
    permissionMode: permissionMode,
    permissionClassifierModel: permissionClassifierModel,
    defaultWorkflow: defaultWorkflow,
    maxTurnTokens: maxTurnTokens,
    maxSessionTokens: maxSessionTokens,
    maxRequestTokens: maxRequestTokens,
    maxGlobalTokens: maxGlobalTokens,
    maxSubAgentTokens: maxSubAgentTokens,
    maxSubAgentDepth: maxSubAgentDepth,
    maxSubAgentConcurrency: maxSubAgentConcurrency,
    requestsPerMinute: requestsPerMinute,
    autoCompactThreshold: autoCompactThreshold,
    maxSteps: maxSteps,
    watchdogSeconds: watchdogSeconds,
    streamIdleTimeout: streamIdleTimeout,
    requestTimeout: requestTimeout,
    promptOverrides: promptOverrides,
    safeMode: safeMode,
    sandboxEnabled: sandboxEnabled,
    sandboxOffReason: sandboxOffReason,
    sandboxNet: sandboxNet,
    sandboxReadOnly: sandboxReadOnly,
    regionsModel: regionsModel,
    modelExplicit: modelExplicit,
    transportRetryAttempts: transportRetryAttempts,
    enableWorkflow: enableWorkflow,
  );

  TerminalConfig get terminal => TerminalConfig(
    backend: backend,
    theme: theme,
    mouseWheel: mouseWheel,
    layout: layout,
  );

  ResumeRequest get resumeRequest => ResumeRequest(
    resumeSessionId: resumeSessionId,
    continueLatest: continueLatest,
  );

  StartupOptions get startup => StartupOptions(
    showHelp: showHelp,
    models: models,
    showVersion: showVersion,
    prompt: prompt,
    listSessions: listSessions,
    resumePicker: resumePicker,
    workflow: workflow,
    verbose: verbose,
    initConfig: initConfig,
    setup: setup,
    trustOverride: trustOverride,
    trustDefault: trustDefault,
    forceLock: forceLock,
    yolo: yolo,
    resume: resumeRequest,
  );

  ResolvedLaunch get launch =>
      ResolvedLaunch(runtime: runtime, terminal: terminal, startup: startup);

  bool get nonInteractive => prompt != null || workflow != null;

  static final _parser = ArgParser()
    ..addOption('base-url')
    ..addOption(
      'max-output-tokens',
      aliases: ['max-tokens'],
      defaultsTo: '${ProviderRegistry.defaultMaxTokens}',
      help: 'Per-response output cap (clamped to the model catalog ceiling).',
    )
    ..addOption(
      'reasoning-effort',
      allowed: _reasoningEfforts,
      help:
          'Reasoning effort for the configured OpenAI-compatible provider. '
          'GLM-5.3/Flash: low, high, max. auto uses the provider default.',
    )
    ..addOption(
      'prompt',
      help: 'Run a single prompt non-interactively and exit.',
    )
    ..addMultiOption(
      'allow',
      help:
          'Allow rule: TOOL:PATTERN, e.g. --allow "bash:git *" '
          '--allow "read:/workspace/**". Can be repeated.',
    )
    ..addMultiOption(
      'deny',
      help:
          'Deny rule: same syntax as --allow. Deny rules take '
          'precedence over allow rules of the same scope.',
    )
    ..addFlag(
      'yolo',
      negatable: false,
      help:
          'Skip all permission prompts AND lift the configurable budgets: '
          'the bash sandbox is disabled (unless --sandbox re-asserts it), '
          'every token cap, the requests-per-minute throttle, the step cap, '
          'and sub-agent depth/concurrency limits are turned off. Explicit '
          'flags win over yolo; --safe-mode and explicit --deny rules still '
          'apply.',
    )
    ..addOption(
      'permission-mode',
      allowed: ['ask', 'read-all', 'allow-edits', 'auto'],
      help:
          'Permission gating: ask (prompt for mutating tools), read-all '
          '(read-only; shell and writes blocked), allow-edits (also auto-approve '
          'file edits; bash still prompts), auto (a classifier model decides '
          'each call, falling back to a prompt).',
    )
    ..addFlag(
      'safe-mode',
      negatable: false,
      help:
          'Read-only session: remove write/edit/bash from every agent and '
          'instruct each it may only read. Inherently --yolo-proof — safe-'
          'mode silently dominates --yolo.',
    )
    ..addFlag(
      'no-sandbox',
      negatable: false,
      help:
          'Disable the OS-level confinement around bash (writes are '
          'otherwise limited to the project root + temp; sandbox-exec on '
          'macOS, bwrap on Linux). Use for commands that must write to '
          '\$HOME or system paths.',
    )
    ..addFlag(
      'sandbox',
      negatable: true,
      defaultsTo: true,
      help:
          'Keep the bash sandbox ON even under --yolo. yolo disables the '
          'sandbox (an unattended run must not stall re-granting write '
          'access), and this flag puts it back. Same effect as omitting '
          '--no-sandbox on a non-yolo run.',
    )
    ..addFlag(
      'sandbox-net',
      negatable: false,
      help:
          'Isolate the bash sandbox from the network (bwrap --unshare-net on '
          'Linux; deny network* on macOS). Off by default: builds, installs, '
          'and git fetch need egress. Gates bash only — fetch/web_search '
          'still reach the network.',
    )
    ..addFlag(
      'sandbox-readonly',
      negatable: false,
      help:
          'Tighten the bash sandbox for read/analyze runs: the project root '
          'stays readable but writable only via temp. Composes with '
          '--sandbox-net; no-op with --no-sandbox.',
    )
    ..addOption(
      'resume',
      valueHelp: 'id',
      help:
          'Resume a saved session; omit the id to choose from saved sessions.',
    )
    ..addFlag(
      'continue',
      abbr: 'c',
      negatable: false,
      help: 'Resume the most recently updated session.',
    )
    ..addFlag(
      'list',
      abbr: 'l',
      negatable: false,
      help: 'List saved sessions and exit.',
    )
    ..addOption(
      'models',
      help:
          'Print the resolved model list for one provider id (one '
          '`<id> — <name>` per line), exit 0. No value passed → print known '
          'provider ids. Unknown provider → stderr with known providers, exit 1.',
    )
    ..addOption(
      'model',
      help:
          'Run this session under a different model. A value containing '
          '"/" is a full \'<provider>/<model>\' reference (provider = FIRST '
          'segment — model ids may themselves contain slashes, e.g. '
          'openrouter/stealth/ox-alpha); a bare value overrides only the '
          'model, keeping the config default provider. On resume, an '
          'explicit `--model` beats the persisted conversation model ref; '
          'without the flag the active conversation\'s meta model wins. '
          'One-shot: never persisted.',
    )
    ..addOption(
      'workflow',
      help:
          'Run a DOT pipeline from ~/.tina/workflows/<name>.dot to '
          'completion (non-interactive). Pair with --prompt for its input.',
    )
    ..addFlag(
      'enable-workflow',
      negatable: false,
      help:
          'Bring back the DOT-workflow surface, which is off by default: the '
          'main agent gets the launch_workflow/stop_workflow tools, its '
          'identity steers it toward launching a workflow for substantial '
          'work, live run panels open, and /workflow is available. Persist '
          'with [features] workflow = true in ~/.tina/config. Does not affect '
          'an explicit --workflow <name> run.',
    )
    ..addOption(
      'max-turn-tokens',
      defaultsTo: '10000000',
      help:
          'Abort a user turn if input+output exceeds this many tokens. '
          'Guard against runaway tool loops. 0 to disable.',
    )
    ..addOption(
      'max-session-tokens',
      defaultsTo: '10000000',
      help:
          'Abort if cumulative session tokens exceed this. '
          'Resets on /clear. 0 to disable.',
    )
    ..addOption(
      'max-request-tokens',
      defaultsTo: '200000',
      help:
          'Refuse to send a request whose input alone exceeds this '
          '(approx). 0 to disable.',
    )
    ..addOption(
      'max-global-tokens',
      defaultsTo: '0',
      help:
          'Hard cap on total tokens across ALL agents this app session '
          '(main + orchestrator + scouts). Trips a hard abort when crossed. '
          '0 falls back to the file default, or unbounded if neither is set.',
    )
    ..addOption(
      'max-sub-agent-tokens',
      defaultsTo: '0',
      help:
          'Per-session token cap for each sub-agent (they otherwise run '
          'uncapped). 0 falls back to the file default, or unbounded.',
    )
    ..addOption(
      'max-sub-agent-depth',
      defaultsTo: '3',
      help:
          'Maximum nesting depth for sub-agent delegation — the root '
          'orchestrator is depth 0, its direct children are depth 0, and so '
          'on. A spawn at this depth or deeper is rejected. Overrides the '
          '[limits] max_sub_agent_depth key.',
    )
    ..addOption(
      'max-sub-agent-concurrency',
      defaultsTo: '6',
      help:
          'Maximum number of sub-agents allowed to run concurrently. '
          'Extra spawns queue until a slot frees. Overrides the [limits] '
          'max_sub_agent_concurrency key.',
    )
    ..addOption(
      'requests-per-minute',
      defaultsTo: '0',
      help:
          'Global requests-per-minute throttle shared by all agents. '
          '0 disables it (or falls back to the file default).',
    )
    ..addOption(
      'auto-compact-threshold',
      defaultsTo: '120000',
      help:
          'Auto-summarize older history when a request\'s estimated input '
          'tokens exceed this — between turns and mid-turn (long tool-using '
          'turns compact in place instead of drowning in accumulated '
          'results), keeping recent turns verbatim. 0 disables.',
    )
    ..addOption(
      'max-steps',
      defaultsTo: '500',
      help:
          'Maximum tool-calling steps allowed in a single user turn. '
          '0 = unbounded (a runaway turn is still caught by the hard '
          'tool-call cap; --yolo implies 0 unless you pass this flag).',
    )
    ..addOption(
      'watchdog-seconds',
      defaultsTo: '300',
      help:
          'Headless only: abort the run when no agent-sink event has '
          'arrived for this long (a silent wedge below the provider stack '
          '— no request is in flight, so no other timeout fires). '
          '0 disables.',
    )
    ..addOption(
      'stream-idle-timeout',
      defaultsTo: '60',
      help:
          'Seconds to wait between SSE events before declaring the '
          'stream dead. Bump for very slow models.',
    )
    ..addOption(
      'request-timeout',
      defaultsTo: '120',
      help:
          'Seconds to wait for response headers per attempt before '
          'aborting the request (scaled up for large request bodies). '
          'Slow providers may need more than the 120s default.',
    )
    ..addOption(
      'transport-retry-attempts',
      defaultsTo: '5',
      help:
          'Headless only: when a provider stream fails MID-response with a '
          'retryable transport error (429/5xx, dropped connection), re-send '
          'the failed step up to this many extra times before aborting the '
          'run. Backs off 15s doubling to a 120s cap, or honors the server '
          'Retry-After. 0 disables — the first mid-stream error aborts.',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the tina version and exit.',
    )
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help:
          'Verbose logging (Level.FINE). Equivalent to COCOON_DEBUG=1; '
          'captures swallowed-exception and lifecycle records in '
          '~/.tina/tina.log.',
    )
    ..addFlag(
      'init-config',
      negatable: false,
      help:
          'Write a commented TOML template to ~/.tina/config (chmod 600) '
          'and exit. Edits there persist provider, model, and API '
          'keys so you can stop passing them on the CLI / as env vars.',
    )
    ..addFlag(
      'setup',
      negatable: false,
      help:
          'Run the interactive first-run setup wizard (provider/model '
          'selection). Also runs automatically when no config exists and '
          'stdin is a terminal.',
    )
    ..addOption(
      'layout',
      allowed: ['sidebar', 'tiled'],
      help:
          'Panel layout: tiled (default) shows spawned conversations side by '
          'side without a conversation list; sidebar adds a left column '
          'listing the conversation tree at the cost of 24 columns of '
          'transcript width. Overrides '
          '[tui] layout in ~/.tina/config (default: tiled).',
    )
    ..addOption(
      'backend',
      allowed: ['ansi', 'notcurses'],
      defaultsTo: 'notcurses',
      help:
          'Rendering backend. "notcurses" (the default) forces notcurses '
          'and exits if it cannot initialize; "ansi" forces the ANSI '
          'renderer.',
    )
    ..addFlag(
      'trust',
      negatable: true,
      help:
          'Override the project-trust gate. --trust loads this '
          'directory\'s AGENTS.md without asking; --no-trust withholds it. '
          'By default tina asks (TUI) or skips (headless) for an untrusted '
          'project. See [trust] default in ~/.tina/config.',
    )
    ..addFlag(
      'force',
      negatable: false,
      help:
          'Force-acquire the per-session lock even if another process '
          'appears to hold it. Use only when that process is gone but its '
          'lock lingers (e.g. after a reboot) — concurrent access to one '
          'session corrupts its history.',
    );

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
    bool showVersion = false,
    String? models,
  }) => Config(
    provider: 'anthropic',
    apiKey: '',
    model: '',
    baseUrl: '',
    maxTokens: 0,
    yolo: false,
    showHelp: showHelp,
    models: models,
    prompt: null,
    permissionRules: const [],
    resumeSessionId: null,
    continueLatest: false,
    listSessions: listSessions,
    showVersion: showVersion,
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
    watchdogSeconds: 0,
    streamIdleTimeout: const Duration(seconds: 60),
    requestTimeout: const Duration(seconds: 30),
    backend: BackendChoice.notcurses,
    verbose: false,
    initConfig: initConfig,
    setup: false,
    trustOverride: null,
    trustDefault: TrustDefault.ask,
    forceLock: false,
  );

  /// args requires option values. Give a bare --resume an empty value while
  /// leaving other options' values and the -- terminator untouched.
  static List<String> _resumeArguments(List<String> argv) {
    final result = <String>[];
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      if (arg == '--') {
        result.addAll(argv.skip(i));
        break;
      }
      if (arg == '--resume' &&
          (i + 1 == argv.length || argv[i + 1].startsWith('-'))) {
        result.add('--resume=');
        continue;
      }
      result.add(arg);
      final option = arg.startsWith('--') && !arg.contains('=')
          ? _parser.options[arg.substring(2)]
          : arg.startsWith('-') && arg.length == 2
          ? _parser.findByAbbreviation(arg.substring(1))
          : null;
      if (option != null && !option.isFlag && i + 1 < argv.length)
        result.add(argv[++i]);
    }
    return result;
  }

  factory Config.parse(
    List<String> argv, {
    Map<String, String>? env,
    ProviderRegistry? registry,
    UserConfig? userConfig,
  }) {
    final res = _parser.parse(_resumeArguments(argv));
    // --help / --init-config / --list short-circuit before provider/key
    // resolution: each runs on a fresh install with no credentials, so none of
    // the parser's real defaults (token budgets, auto-compact, etc.) matter —
    // main() reads only the short-circuit flag and exits. The three share one
    // placeholder Config that differs solely in which flag is set.
    if (res['help'] as bool) return _shortCircuitConfig(showHelp: true);

    // --version: main() prints tinaVersion and exits.
    if (res['version'] as bool) return _shortCircuitConfig(showVersion: true);

    // --init-config: main() writes a commented TOML template and exits.
    if (res['init-config'] as bool)
      return _shortCircuitConfig(initConfig: true);

    // --list: main() prints saved sessions and exits — only the on-disk store
    // is needed, not credentials.
    if (res['list'] as bool) return _shortCircuitConfig(listSessions: true);

    registry ??= builtinRegistry();
    env ??= Platform.environment;

    // --model (flag > file): a value containing '/' is a full
    // '<provider>/<model>' reference — the provider is the FIRST segment only,
    // because model ids may themselves contain slashes (e.g.
    // openrouter/stealth/ox-alpha). The same split convention lives in
    // session_restore.dart. A bare value overrides just the model and keeps
    // the config default provider. Parsed BEFORE the descriptor lookup so a
    // swapped provider drives everything derived from it below: the
    // unknown-provider FormatException, the API-key auth scan, the
    // <PROVIDER>_MODEL / _BASE_URL env prefix, the default base URL, and the
    // default model fallback. One-shot: it lands on [Config]
    // fields only and is never persisted to ~/.tina/config.
    final flagModel = res['model'] as String?;
    String providerId;
    final String modelOverride;
    if (flagModel != null && flagModel.contains('/')) {
      providerId = flagModel.split('/').first;
      modelOverride = flagModel.substring(flagModel.indexOf('/') + 1);
    } else {
      providerId = userConfig?.defaultProvider ?? 'anthropic';
      modelOverride = flagModel ?? '';
    }

    // Provider precedence: config file > 'anthropic' default; a full --model
    // ref beats both.
    final desc = registry.descriptor(providerId);
    if (desc == null) {
      throw FormatException(
        'Unknown provider "$providerId". '
        'Known: ${registry.providerIds.join(', ')}',
      );
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
    //
    // Precedence is file > env: the config-file overlay merged into [env] by
    // main() (buildEnvOverlay) wins over the plain environment, and authFor's
    // scan does the rest. There is deliberately NO --api-key flag: a key on a
    // command line leaks via shell history, process listings, and audit logs —
    // credentials belong in ~/.tina/config or the environment (owner
    // decision, 2026-08-21; the flag shipped briefly and was removed).
    final apiKey = registry.authFor(desc, env: env).key;

    // Per-provider env overrides by convention: <PROVIDER>_MODEL / _BASE_URL.
    final envPrefix = providerId.toUpperCase();
    final defaultModel =
        env['${envPrefix}_MODEL'] ??
        (desc.models.isNotEmpty ? desc.models.keys.first : '');
    final defaultBaseUrl = env['${envPrefix}_BASE_URL'] ?? desc.defaultBaseUrl;

    final maxTokens =
        int.tryParse(res['max-output-tokens'] as String) ??
        ProviderRegistry.defaultMaxTokens;

    final effort =
        res['reasoning-effort'] as String? ?? userConfig?.reasoningEffort;
    if (effort != null && !_reasoningEfforts.contains(effort)) {
      throw FormatException('Invalid reasoning_effort: $effort');
    }
    final reasoningEffort = effort == 'auto' ? null : effort;

    // Deny rules first so they win same-pattern ties.
    final rules = <PermissionRule>[
      for (final s in res['deny'] as List<String>)
        parsePermissionRule(s, PermissionDecision.deny),
      for (final s in res['allow'] as List<String>)
        parsePermissionRule(s, PermissionDecision.allow),
    ];

    // Model tiers were removed with the delegate catalog (a delegation now
    // carries its own llm_provider/llm_model). Nothing to parse here.

    final resumeValue = res['resume'] as String?;
    final resumePicker = resumeValue == '';
    final resumeId = resumePicker ? null : resumeValue;
    final continueLatest = res['continue'] as bool;
    if (resumeValue != null && continueLatest) {
      throw const FormatException(
        '--resume and --continue are mutually exclusive.',
      );
    }

    if (resumePicker && (res['prompt'] != null || res['workflow'] != null)) {
      throw const FormatException(
        'Use --resume <id> with --prompt or --workflow. '
        'Use --list to see saved sessions.',
      );
    }

    int parseBudget(String name, String defaultValue) {
      final raw = (res[name] as String?) ?? defaultValue;
      final n = int.tryParse(raw);
      if (n == null || n < 0) {
        throw FormatException(
          '--$name must be a non-negative integer; got "$raw"',
        );
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
    // tin-y9k2: under --yolo the file tier is skipped — the user asked for a
    // run nothing may throttle — so the chain becomes CLI > --yolo > file >
    // default. The CLI tier still dominates yolo: `--yolo --max-steps 50`
    // stops at 50. `0` here means "cap off" everywhere it flows.
    final yolo = res['yolo'] as bool;
    int parseLimit(String name, int? fileValue, int defaultValue) {
      if (res.wasParsed(name)) {
        final raw = res[name] as String;
        final n = int.tryParse(raw);
        if (n == null || n < 0) {
          throw FormatException(
            '--$name must be a non-negative integer; got "$raw"',
          );
        }
        return n;
      }
      if (yolo) return 0;
      return fileValue ?? defaultValue;
    }

    final fileLimits = userConfig?.limits;

    // Sandbox posture, precedence: explicit flag > --yolo > defaults. The
    // parser maps --sandbox/--no-sandbox into a tri-state via wasParsed:
    // unparsed = the user said nothing (so --yolo may turn the sandbox off),
    // parsed true/false = explicit intent, which always wins. See tin-y9k2.
    final sandboxFlag = res.wasParsed('sandbox')
        ? res['sandbox'] as bool
        : null;
    final explicitNoSandbox = res['no-sandbox'] as bool;
    final bool sandboxEnabled;
    final String? sandboxOffReason;
    if (explicitNoSandbox || sandboxFlag == false) {
      sandboxEnabled = false;
      sandboxOffReason = kSandboxOffReasonNoSandbox;
    } else if (sandboxFlag == true) {
      sandboxEnabled = true; // explicit on, even under --yolo
      sandboxOffReason = null;
    } else if (res['yolo'] as bool) {
      sandboxEnabled = false;
      sandboxOffReason = kSandboxOffReasonYolo;
    } else {
      sandboxEnabled = true;
      sandboxOffReason = null;
    }

    return Config(
      provider: providerId,
      apiKey: apiKey,
      model: modelOverride.isNotEmpty
          ? modelOverride
          : userConfig?.defaultModel ?? defaultModel,
      baseUrl: (res['base-url'] as String?) ?? defaultBaseUrl,
      maxTokens: maxTokens,
      reasoningEffort: reasoningEffort,
      yolo: res['yolo'] as bool,
      showHelp: false,
      showVersion: false,
      prompt: res['prompt'] as String?,
      models: res['models'] as String?,
      permissionRules: rules,
      resumeSessionId: resumeId,
      resumePicker: resumePicker,
      continueLatest: continueLatest,
      listSessions: false,
      workflow: res['workflow'] as String?,
      defaultWorkflow: userConfig?.defaultWorkflow,
      maxTurnTokens: parseLimit(
        'max-turn-tokens',
        fileLimits?.maxTurnTokens,
        1000000,
      ),
      maxSessionTokens: parseLimit(
        'max-session-tokens',
        fileLimits?.maxSessionTokens,
        10000000,
      ),
      maxRequestTokens: parseLimit(
        'max-request-tokens',
        fileLimits?.maxRequestTokens,
        200000,
      ),
      maxGlobalTokens: parseLimit(
        'max-global-tokens',
        fileLimits?.maxGlobalTokens,
        50000000,
      ),
      maxSubAgentTokens: parseLimit(
        'max-sub-agent-tokens',
        fileLimits?.maxSubAgentTokens,
        2000000,
      ),
      maxSubAgentDepth: parseLimit(
        'max-sub-agent-depth',
        fileLimits?.maxSubAgentDepth,
        3,
      ),
      maxSubAgentConcurrency: parseLimit(
        'max-sub-agent-concurrency',
        fileLimits?.maxSubAgentConcurrency,
        6,
      ),
      requestsPerMinute: parseLimit(
        'requests-per-minute',
        fileLimits?.requestsPerMinute,
        0,
      ),
      autoCompactThreshold: parseBudget(
        'auto-compact-threshold',
        kDefaultAutoCompactThreshold,
      ),
      // tin-y9k2: --max-steps accepts 0 = unbounded. There is no [limits]
      // file key for it, so the chain is CLI > --yolo(0) > default.
      maxSteps: res.wasParsed('max-steps')
          ? parseBudget('max-steps', kDefaultMaxSteps.toString())
          : yolo
          ? 0
          : kDefaultMaxSteps,
      watchdogSeconds: parseBudget(
        'watchdog-seconds',
        kDefaultWatchdogSeconds.toString(),
      ),
      streamIdleTimeout: Duration(
        seconds: parsePositive(
          'stream-idle-timeout',
          kDefaultStreamIdleTimeoutSeconds.toString(),
        ),
      ),
      requestTimeout: Duration(
        seconds: parsePositive(
          'request-timeout',
          kDefaultRequestTimeoutSeconds.toString(),
        ),
      ),
      transportRetryAttempts: parseBudget(
        'transport-retry-attempts',
        kDefaultTransportRetryAttempts.toString(),
      ),
      backend: switch (res['backend'] as String) {
        'ansi' => BackendChoice.ansi,
        _ => BackendChoice.notcurses,
      },
      verbose: res['verbose'] as bool,
      initConfig: res['init-config'] as bool,
      setup: res['setup'] as bool,
      promptOverrides: userConfig?.prompts ?? const {},
      theme: _resolveTheme(userConfig),
      safeMode: res['safe-mode'] as bool,
      sandboxEnabled: sandboxEnabled,
      sandboxOffReason: sandboxOffReason,
      sandboxNet: res['sandbox-net'] as bool,
      sandboxReadOnly: res['sandbox-readonly'] as bool,
      trustOverride: res.wasParsed('trust') ? res['trust'] as bool : null,
      trustDefault: _parseTrustDefault(userConfig?.trustDefault),
      mouseWheel: userConfig?.mouseWheel ?? false,
      layout: _resolveLayout(res['layout'] as String?, userConfig?.layout),
      regionsModel: userConfig?.regions?.model,
      permissionMode: _resolvePermissionMode(
        res['permission-mode'] as String?,
        userConfig?.permissions?.mode,
      ),
      permissionClassifierModel: userConfig?.permissions?.model,
      modelExplicit: res.wasParsed('model'),
      forceLock: res['force'] as bool,
      enableWorkflow:
          (res['enable-workflow'] as bool) ||
          (userConfig?.featuresWorkflow ?? false),
    );
  }
}

LayoutStyle _resolveLayout(String? flagValue, String? fileValue) =>
    switch (flagValue ?? fileValue) {
      null || 'tiled' => LayoutStyle.tiled,
      'sidebar' => LayoutStyle.sidebar,
      final value => throw FormatException(
        'Invalid [tui] layout "$value": expected sidebar or tiled.',
      ),
    };

/// Resolve the startup permission mode: CLI flag > `[permissions] mode` file
/// value > ask. An unknown file value is a config error at load time, but be
/// defensive here too — unknown → ask.
PermissionMode _resolvePermissionMode(String? flagValue, String? fileValue) {
  final raw = flagValue ?? fileValue;
  if (raw == null) return PermissionMode.ask;
  return switch (raw) {
    'ask' => PermissionMode.ask,
    'read-all' || 'read_all' => PermissionMode.readAll,
    'allow-edits' || 'allow_edits' => PermissionMode.allowEdits,
    'auto' => PermissionMode.auto,
    _ => PermissionMode.ask,
  };
}

/// Resolve the user's [Theme] from [UserConfig], applying the `variant` key
/// when no explicit per-key overrides are set.
///
/// Priority: explicit per-key [Theme] overrides > named variant > shipped defaults.
Theme _resolveTheme(UserConfig? uc) {
  if (uc?.theme != null) return themeFromOverrides(uc!.theme);
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

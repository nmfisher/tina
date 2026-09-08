import 'package:tina_engine/tina_engine.dart';

import 'environment_options.dart';
export 'environment_options.dart';

/// Immutable execution settings, independent of parsing, persistence and terminal UI.
class RuntimeConfig {
  /// Registry provider id, e.g. "anthropic", "openai", "glm".
  final String provider;

  final String apiKey;

  final String model;

  final String baseUrl;

  final int maxTokens;

  final bool yolo;

  final List<PermissionRule> permissionRules;

  /// Startup permission mode (`--permission-mode` / `[permissions] mode`).
  final PermissionMode permissionMode;

  /// `"provider/model"` for the "auto" mode's safety classifier
  /// (`[permissions] model`); null = inherit the main model.
  final String? permissionClassifierModel;

  /// DOT workflow every normal chat turn routes through (`[default] workflow`
  /// in ~/.tina/config). `"none"` disables the presence-based `default.dot`
  /// routing; null/absent means "use `default.dot` when it exists".
  final String? defaultWorkflow;

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

  /// Headless liveness timeout (#26): no agent-sink event for this long
  /// aborts the run with a diagnostic and exit 2 — Run D sat in a silent
  /// futex wait 25+ minutes past its last wire request because the hang was
  /// below the provider stack where no request timeout applies. 0 disables.
  final int watchdogSeconds;

  /// How long an SSE stream may be silent before we treat it as dead.
  /// Generous default so a slow completion doesn't fail spuriously.
  final Duration streamIdleTimeout;

  /// How long to wait for response headers on a single HTTP attempt (LLM
  /// requests). Threaded through to [sendWithRetry]. Distinct from
  /// [streamIdleTimeout], which covers silence *during* the SSE stream.
  final Duration requestTimeout;

  /// `name → identity` system-prompt override from the `[prompts.main]` config
  /// table. The entry agent's identity is overridable here; a sub-agent inherits
  /// its parent's resolved prompt, so the override propagates down. An absent
  /// `main` entry means "use the built-in default identity". Empty by default.
  final Map<String, String> promptOverrides;

  /// Read-only session (`--safe-mode`): `write`/`edit`/`bash` are removed from
  /// every agent and each is told it may only read. Inherently `--yolo`-proof
  /// (yolo only relaxes the ask-gate; the tools simply don't exist). Defaults
  /// off, so the `--help`/`--init-config`/`--list` short-circuits need no change.
  final bool safeMode;

  /// `--no-sandbox`: when false (the default), bash subprocesses run under an
  /// OS-level write confinement — `sandbox-exec` on macOS, `bwrap` on Linux —
  /// with writes limited to the project root + temp, so a runaway
  /// `rm`/`find -delete` can't reach outside the project. `--no-sandbox`
  /// disables it (e.g. for commands that must write to `$HOME`). Where no
  /// backend exists (or bwrap/user namespaces are unavailable on Linux) the
  /// sandbox degrades to pass-through with a one-time warning.
  final bool sandboxEnabled;

  /// `--sandbox-net`: opt-in network isolation for the bash sandbox —
  /// `--unshare-net` under bwrap on Linux, `(deny network*)` + remote-write
  /// deny under sandbox-exec on macOS. Off by default: builds, installs, and
  /// `git fetch` need egress. Covers bash subprocesses only; the `fetch` /
  /// `web_search` tools are NOT gated (a known residual egress path — see
  /// docs/features/sandbox.md).
  final bool sandboxNet;

  /// `--sandbox-readonly`: opt-in tighter containment — drop the sandbox's
  /// writable project grant (project stays readable), keep temp writable. For
  /// pure read/analyze runs (`--prompt` reviews, audits). Like `--no-sandbox`,
  /// a no-op where no backend exists.
  final bool sandboxReadOnly;

  /// First-load environment-agent behavior from `[environment] auto_populate`
  /// in ~/.tina/config (`ask`/`always`/`never`). `ask` (the default) shows a
  /// picker on first load; `always` runs without asking; `never` skips.
  final EnvironmentAutoPopulate environmentAutoPopulate;

  /// The environment agent's `"provider/model"` from `[environment] model` in
  /// ~/.tina/config. Null when absent → the shipped default
  /// (`kDefaultEnvironmentModelRef`). Distinct from the startup model: the
  /// environment agent is a dedicated one-off worker with its own model pick.
  final String? environmentModel;

  /// The default `"provider/model"` for region agents from `[regions] model` —
  /// the fast tier the main agent routes scoped questions to. null = region
  /// agents inherit the main agent's model.
  final String? regionsModel;

  /// Whether `--model` was explicitly passed by the user. Must be carried
  /// separately from [model] because resume precedence depends on whether
  /// the user explicitly overrode the model: when `modelExplicit` is false,
  /// a resumed session's active conversation meta model ref takes precedence
  /// over the config file / default; when true, the CLI flag wins.
  final bool modelExplicit;

  /// Turn-level transport retries for the HEADLESS runner (#28): when a
  /// provider stream fails MID-response with a transport-retryable error
  /// (429/5xx, dropped connection), the agent re-sends the failed step up to
  /// this many extra times (15s → 120s exponential backoff, or the server's
  /// Retry-After capped at 120s when it supplies one) before aborting the
  /// run. 0 disables — the first mid-stream error aborts as before. Read by
  /// bin/tina.dart only; the TUI does not opt in.
  final int transportRetryAttempts;

  RuntimeConfig({
    this.provider = 'anthropic',
    this.apiKey = '',
    this.model = '',
    this.baseUrl = '',
    this.maxTokens = 8192,
    this.yolo = false,
    List<PermissionRule> permissionRules = const [],
    this.permissionMode = PermissionMode.ask,
    this.permissionClassifierModel,
    this.defaultWorkflow,
    this.maxTurnTokens = 1000000,
    this.maxSessionTokens = 10000000,
    this.maxRequestTokens = 200000,
    this.maxGlobalTokens = 50000000,
    this.maxSubAgentTokens = 2000000,
    this.maxSubAgentDepth = 3,
    this.maxSubAgentConcurrency = 6,
    this.requestsPerMinute = 0,
    this.autoCompactThreshold = 120000,
    this.maxSteps = 500,
    this.watchdogSeconds = 300,
    this.streamIdleTimeout = const Duration(seconds: 60),
    this.requestTimeout = const Duration(seconds: 30),
    Map<String, String> promptOverrides = const {},
    this.safeMode = false,
    this.sandboxEnabled = true,
    this.sandboxNet = false,
    this.sandboxReadOnly = false,
    this.environmentAutoPopulate = EnvironmentAutoPopulate.ask,
    this.environmentModel,
    this.regionsModel,
    this.modelExplicit = false,
    this.transportRetryAttempts = 5,
  }) : permissionRules = List.unmodifiable(permissionRules),
       promptOverrides = Map.unmodifiable(promptOverrides);

  /// Build a token budget from the parsed flags. 0 in any field disables
  /// that particular cap; if all three are 0 the budget is itself null.
  TokenBudget? buildTokenBudget() {
    if (maxTurnTokens == 0 && maxSessionTokens == 0 && maxRequestTokens == 0) {
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
  /// The permission mode rides along on the policy (consulted at check time,
  /// switchable at runtime via `/permissions <mode>`).
  PermissionPolicy buildPolicy() {
    final defaults = yolo
        ? {
            'read': PermissionDecision.allow,
            'write': PermissionDecision.allow,
            'edit': PermissionDecision.allow,
            'bash': PermissionDecision.allow,
          }
        : null;
    return PermissionPolicy(
      defaults: defaults,
      rules: permissionRules,
      mode: permissionMode,
    );
  }
}

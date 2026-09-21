import 'package:tina_engine/tina_engine.dart';

/// Immutable execution settings, independent of parsing, persistence and terminal UI.
class RuntimeConfig {
  /// Registry provider id, e.g. "anthropic", "openai", "glm".
  final String provider;

  final String apiKey;

  final String model;

  final String baseUrl;

  final int maxTokens;

  /// Optional wire reasoning effort for the configured provider.
  final String? reasoningEffort;

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

  /// `--no-sandbox` / `--yolo` / `--sandbox`: when false (the default), bash
  /// subprocesses run under an OS-level write confinement — `sandbox-exec` on
  /// macOS, `bwrap` on Linux — with writes limited to the project root + temp,
  /// so a runaway `rm`/`find -delete` can't reach outside the project.
  /// `--no-sandbox` disables it; `--yolo` also disables it (it must not stop
  /// to re-grant write access mid-run) unless `--sandbox` re-asserts the flag.
  /// Where no backend exists (or bwrap/user namespaces are unavailable on
  /// Linux) the sandbox degrades to pass-through with a one-time warning.
  final bool sandboxEnabled;

  /// Why [sandboxEnabled] is false — who turned the sandbox off, so the chip,
  /// the startup notice, and the log can say `--no-sandbox` vs `--yolo`
  /// instead of a generic "off". Null when the sandbox is on.
  final String? sandboxOffReason;

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

  /// Whether the DOT-workflow surface exists at all (`--enable-workflow`, or
  /// `[features] workflow = true` in ~/.tina/config). **Off by default**: the
  /// built-in `default` graph earned its keep poorly, so the main agent is no
  /// longer handed `launch_workflow`/`stop_workflow`, its identity no longer
  /// steers it toward launching one, the live run panels are never reachable,
  /// and `/workflow` is hidden. Nothing was deleted — every piece is still
  /// wired behind this flag, so bringing the surface back is one setting.
  ///
  /// This gates the *interactive/default* surface only. The explicit
  /// `--workflow <name>` launch (a named graph run to completion, no TUI) is
  /// a deliberate one-shot the user typed, and is unaffected.
  final bool enableWorkflow;

  RuntimeConfig({
    this.provider = 'anthropic',
    this.apiKey = '',
    this.model = '',
    this.baseUrl = '',
    // Shared engine default (ProviderRegistry.defaultMaxTokens) so every
    // layer agrees; clamped per model at provider build time.
    this.maxTokens = ProviderRegistry.defaultMaxTokens,
    this.reasoningEffort,
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
    this.requestTimeout = const Duration(seconds: 120),
    Map<String, String> promptOverrides = const {},
    this.safeMode = false,
    this.sandboxEnabled = true,
    this.sandboxOffReason = kSandboxOffReasonNoSandbox,
    this.sandboxNet = false,
    this.sandboxReadOnly = false,
    this.regionsModel,
    this.modelExplicit = false,
    this.transportRetryAttempts = 5,
    this.enableWorkflow = false,
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

  /// Build a policy from the parsed config. `--yolo` sets the policy's
  /// allow-all posture: EVERY tool's default becomes allow (mapped and
  /// unmapped alike) without restating a tool list, so a tool added later
  /// cannot fall back to `ask`. CLI rules layer on top unchanged (so
  /// `--yolo --deny 'bash:rm *'` still denies).
  /// The permission mode rides along on the policy (consulted at check time,
  /// switchable at runtime via `/permissions <mode>`); a mode's hard boundary
  /// (read-all's execution block) still applies under `--yolo`.
  PermissionPolicy buildPolicy() {
    return PermissionPolicy(
      rules: permissionRules,
      mode: permissionMode,
      allowAllByDefault: yolo,
    );
  }
}

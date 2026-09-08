# A02 — Separate runtime, terminal and startup configuration

Status: implemented and validated (2026-09-08). See the [program index](README.md).

## Implementation

`lib/config/runtime_config.dart` now owns immutable runtime values and policy /
budget construction. Permission rules and prompt overrides are defensive copies.
`TerminalConfig`, `StartupOptions`, `ResumeRequest` and `ResolvedLaunch` separate
frontend settings, root actions and session selection. `Config.parse` remains the
root resolver and compatibility facade, preserving the existing parser's defaults,
validation and early-exit order; `.launch` projects it into the three owned values.
The CLI passes plain runtime settings, an explicit resume request and terminal
settings to their respective consumers. Explicit model-source metadata remains
`RuntimeConfig.modelExplicit` so provider resolution retains resume precedence.

Composition, provider resolution, agents, summary/environment services and restore
now accept `RuntimeConfig`. `resolveSession` accepts `ResumeRequest`. During
migration, `Config` extends the runtime value and implements the resume contract;
`buildAppComposition` accepts that legacy selection when no explicit request is
supplied. New code should pass `.runtime` and `.resumeRequest`, or construct runtime
fixtures directly. The TUI likewise has a legacy facade fallback when no explicit
`TerminalConfig` is supplied; production supplies it explicitly.

`UserConfig.theme` is now `ThemeOverrides`, a deeply copied plain-data value.
`theme_mapper.dart` constructs the existing console theme with the same defaults.
Variant selection remains separate from the override map, including on reload and
`copyWith`. The TOML schema and existing valid color/style values are unchanged;
raw override values are retained until the frontend mapper applies defaults.
No user-config schema version or persisted session fields were added.

The fresh picker credential lookup moved to `config/provider_selection.dart`;
neutral provider resolution no longer imports the TOML loader. Existing settings
and model-picker reload points remain intact. Closing the final transitive
terminal dependency required `PipelineRunner` to accept an interviewer builder
and node-start callback. The TUI supplies its existing interviewer, shared modal
queue and panel formatting; `HeadlessInterviewer` preserves noninteractive gate
answers. Loop-budget extension remains available only with a supplied interviewer.

The application closures tested in `test/config/runtime_boundary_test.dart`
contain no terminal packages, argument parser or TOML loader. The test walks
imports, exports, parts and conditional alternatives using the analyzer AST and
package map, including transitive third-party dependencies. Persisted config has
its own terminal-free closure check. Broader repository rules remain A07's task.

## Field and resolution inventory

The defaults below describe normal launch. Informational early exits deliberately
retain their existing placeholder values and bypass provider/value resolution.
The resolver remains authoritative for validation, including the historical
`maxTokens` integer fallback; this change does not tighten accepted CLI values.
Runtime fixtures may construct values directly without parsing arguments.

| Runtime fields | Resolution / normal default |
| --- | --- |
| `provider` | Full CLI `--model provider/model` > file default provider > `anthropic` |
| `model`, `modelExplicit` | Nonempty CLI model > file default model > provider MODEL environment > descriptor first model; explicit flag metadata controls resumed-model precedence |
| `apiKey` | Registry auth-source scan over root's file-over-environment overlay; empty remains legal for setup; no CLI key flag |
| `baseUrl` | CLI base URL > selected provider BASE_URL environment (including root's file overlay) > descriptor URL |
| `maxTokens` | CLI integer / 8192 fallback |
| `permissionRules`, `yolo` | CLI deny rules before allow rules; yolo defaults false; fresh mutable policies are constructed from the immutable rules |
| `permissionMode`, `permissionClassifierModel` | CLI permission mode > file mode > ask; classifier ref from file, otherwise inherit main model |
| `defaultWorkflow` | File default workflow; null retains default.dot discovery; `none` disables it |
| `maxTurnTokens`, `maxSessionTokens`, `maxRequestTokens` | CLI > file limit > 1,000,000 / 10,000,000 / 200,000; zero disables cap |
| `maxGlobalTokens`, `maxSubAgentTokens` | CLI > file limit > 50,000,000 / 2,000,000; zero disables cap |
| `maxSubAgentDepth`, `maxSubAgentConcurrency` | CLI > file limit > 3 / 6 |
| `requestsPerMinute` | CLI > file limit > 0 (unlimited) |
| `autoCompactThreshold`, `maxSteps` | CLI > 120,000 / 500; compaction accepts zero, steps must be positive |
| `watchdogSeconds`, `transportRetryAttempts` | CLI > 300 / 5; zero disables; currently consumed by headless execution |
| `streamIdleTimeout`, `requestTimeout` | CLI positive seconds > 60 / 30 |
| `promptOverrides` | File prompts; default empty; runtime takes immutable snapshot |
| `safeMode`, `sandboxEnabled`, `sandboxNet`, `sandboxReadOnly` | CLI flags; false / true / false / false |
| `environmentAutoPopulate`, `environmentModel`, `regionsModel` | File values; ask / null / null; model pickers may supply a fresh explicit override per operation |

| Terminal/startup fields | Resolution / ownership |
| --- | --- |
| `backend`, `theme`, `mouseWheel` | Backend CLI > notcurses; theme from file overrides / named preset / existing console defaults; wheel from file > false |
| `showHelp`, `showVersion`, `initConfig`, `listSessions` | CLI early actions, in existing precedence order; no provider construction |
| `models`, `setup` | CLI actions; existing registry/parse ordering retained |
| `prompt`, `workflow`, `nonInteractive` | CLI inputs; either input selects headless mode |
| `resumeSessionId`, `continueLatest` | ResumeRequest; CLI options are mutually exclusive; no selection means fresh session |
| `verbose`, `forceLock` | CLI flags; existing root logging also consults COCOON_DEBUG |
| `trustOverride`, `trustDefault` | Explicit CLI trust override; file default ask/always/never, otherwise ask |

Persisted `UserConfig` fields remain the same: default provider/model/workflow,
provider descriptors/credentials/pools/model lists/rate settings, limits, prompts,
theme overrides/variant, trust default, environment settings, mouse wheel,
regions and permissions. Parsing and writes stay root-owned. Credentials are not
added to diagnostic strings or copied into new persistence fields. Runtime
snapshots do not replace fresh loads performed by settings and picker flows.

## Validation evidence

Coverage includes parser/file/env/CLI precedence, early exits, resume model
selection, immutable runtime/theme collections, fresh policy construction,
provider override scoping, TUI setup, background execution and injected workflow
adapters. All 437 targeted tests passed and `dart analyze` reported no issues.
See [HANDOFF.md](HANDOFF.md) for the exact validation command.

## Original problem and source anchors

[`Config`](../../../lib/config.dart) combines CLI parsing, runtime policy,
provider credentials, terminal backend selection and a console `Theme`.
[`user_config.dart`](../../../lib/config/user_config.dart) also handles theme
values. Application composition and summary/environment services accept this
large object, transitively importing terminal code into otherwise neutral work.

## Goals

Runtime consumers receive immutable, validated settings with no terminal or
argument-parser types. Preserve the external configuration format and resolution
behavior. This is a representation and dependency change, not a defaults reset.

## Configuration model

| Type | Contents | Owner |
| --- | --- | --- |
| `RuntimeConfig` | Model choice, request limits, token budgets, permission and sandbox policy, tool settings, prompt overrides, workflow defaults | Application layer; later `tina_app` |
| `TerminalConfig` | Backend choice, theme settings and terminal presentation options | Root frontend |
| `StartupOptions` | Help/version/init/setup/list actions, selected execution mode, resume/continue selection, verbosity | Root CLI |
| `ResolvedLaunch` | The three values plus explicit source information needed for resume precedence | Root composition |

Use small nested values only where a real consumer benefits, such as
`ProviderOptions`, `BudgetOptions` and `SandboxOptions`. Do not create a class
for each flag. Collections must be defensive immutable copies.

Persisted session resolution belongs to startup/application operations, not
terminal configuration. Pass an explicit `ResumeRequest` to those operations
instead of giving them the entire `StartupOptions` object.

## Parsing and resolution pipeline

1. Parse arguments sufficiently to retain existing early exits and errors.
2. Load the user configuration through a replaceable loader at the root.
3. Resolve CLI, file, environment and default values into validated settings.
4. Resolve startup/session selection using explicit source metadata.
5. Map terminal color settings to the console `Theme` at frontend construction.

The pipeline must preserve the current ordering of early exits: commands such as
help/version must not start providers, require credentials or initialize a
terminal. Record existing precedence field by field before moving the parser;
do not infer one universal precedence rule for all settings.

Retain the equivalent of `modelExplicit`. An explicitly supplied CLI model must
still override the resumed conversation model; without it, the saved model is
considered before the configured default. Preserve current API-key/base-URL
scoping to the selected provider and existing fallback diagnostics.

### Theme and user configuration

Represent parsed theme overrides as plain color/style values outside the console
package. A root mapper constructs `Theme`. Runtime services must not import the
TOML loader or the theme mapper. `TerminalConfig` itself may use terminal types
because it remains a frontend type; those types cannot appear in `RuntimeConfig`.

Settings and model-picker flows currently reload user configuration. Preserve
that freshness using a root-owned loader followed by an explicit runtime update
or a fresh operation request. Immutable configuration must not freeze settings
that currently change during a live session.

## API migration

Change `buildAppComposition` to receive runtime settings and a separate startup
request. Agent construction gets only runtime settings. Summary/environment
services receive narrower options or the injected factories from A05.

Retain a short-lived `Config` facade for existing CLI call sites while migrating
tests. It may expose `runtime`, `terminal` and `startup`, but new application
consumers must not depend on the facade. Remove it or confine it to the root
once all consumers have migrated.

## Implementation steps

1. Inventory every `Config`/`UserConfig` field and classify ownership, defaults,
   source precedence, live-update behavior and serialization needs.
2. Introduce value types and a resolver. Reuse existing parsing functions first.
3. Migrate composition and provider resolution, followed by services and commands.
4. Migrate terminal construction, settings/setup overlays and theme mapping.
5. Replace tests that invoke `Config.parse` only to construct an agent with
   explicit runtime fixtures; retain parser tests at the root.
6. Remove terminal imports from the application closure and enable A07's rule.

## Tests and acceptance criteria

- Table-driven tests cover existing default/file/env/CLI resolution cases,
  explicit-versus-inherited model selection, and invalid values.
- Help/version/list/setup behavior and existing error wording remain covered by
  CLI tests; no provider construction occurs on pure informational early exits.
- Theme overrides produce the same theme through the frontend mapper.
- Settings changes take effect at the same operation boundary as before.
- Runtime settings and their transitive imports contain no `tina_console`,
  `dart_notcurses`, root parser or `args` dependency.
- No config serialization change is required; existing TOML fixtures still load.
- Provider secrets are neither added to diagnostic `toString` output nor copied
  into new persistence fields.

## Review risks

The largest risks are losing explicit-source information, applying a provider's
credential override to a different provider, and breaking early exits by eager
validation. Characterize these before changing object shape. Keep data migration
out of this work; none is necessary.

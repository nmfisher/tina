# A02 — Separate runtime, terminal and startup configuration

Status: proposed. See the [program index](README.md).

## Problem and source anchors

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

# Engine2 configuration

The root CLI and `tina_tui` share the same reader. Global TOML lives at
`~/.tina/config` (`--config FILE` overrides it). `/settings` and `--configure`
edit it, preserving unknown legacy tables. Saving is atomic, uses mode 0600,
and rejects externally changed files. Generation settings has two controls: **Output limit** (Automatic or a number)
and **Thinking** (choices for the selected model). GLM-5.3 offers Automatic,
Low, High and Max; it cannot turn thinking off. Use arrows to select,
type an output limit, Ctrl-U to restore Automatic output, and left/right to
choose thinking. **Enter saves this section; Esc cancels its edits.** No second
Save action is needed. Choices apply to the displayed provider, including
after restart/resume; unrelated settings drafts are not saved with them.
Automatic output uses model metadata, then the global fallback. An explicit
number takes precedence. Automatic thinking uses provider defaults; choosing
a thinking level replaces the old budget/effort combination automatically.
Existing custom thinking budgets remain visible and can be replaced using the
same control. Other unsaved settings still offer Save, Discard or Keep editing.
`/settings` can open while a model request or tool is running. Saved generation
settings apply to the next model request; the current request continues with its
original values. Theme changes apply immediately. Other startup settings apply
on the next launch.
**Plugins** in `/settings` applies supported plugin changes between turns.
Choose Global, Workspace or Session scope. Space/Enter toggles a checkbox;
Ctrl-R restores inheritance. Toggles save immediately, even if you leave settings
without saving other fields. The checkbox reflects the chosen scope; each row
also shows its source, active state and any pending restart. Required plugins
are locked. Highlighting a plugin shows its description from registration
metadata; `?` opens the full description. `--configure` has no live session, so its checkboxes use Save changes.

See the [config compatibility audit](engine2-config-audit.md) for the exact
consumed/ignored keys, credential precedence and verification of the existing
local config. Legacy cached provider definitions are read offline at startup.

## Plan and approval presentation

The single `tina/plans` plugin attaches a live plan panel in the terminal: step
states, child steps, completion counts and approval state. Ctrl-P toggles visibility.
Press Ctrl-G, Tab to highlight the plan, then Enter to focus it. Up/Down select
items; Enter expands or collapses the full item text and its child steps.
Page Up/Down or the wheel scroll long details. Esc returns to the conversation
with the input draft preserved. Approval uses A, rejection uses R, and Space
toggles the selected step's progress. Browsing never submits input or approves
the plan. Small terminals collapse the unfocused panel to the active step;
focusing it opens the scrollable list. Selection and expansion survive progress
updates. Each conversation owns its plan and panel attachment.

Tool plugins provide optional action descriptions with their tool schemas;
the transcript, activity browser and approvals use those descriptions for
plain-language labels. `tina/approvals-tui` renders permissions above the input
line with the actual command, directory, affected file or colored edit preview.
Y allows the invocation once, N denies, and A remembers the displayed scope
for the session: this file, or this exact command in this directory. Choices
share one row when space permits. Arrows/Enter also work; Tab opens scrollable
technical details, and Esc cancels. Generic confirmations retain Yes/No.
One-call approval includes the tool's atomic temporary-file/rename work,
and expires after the invocation. Request details are channel-neutral metadata;
the engine does not depend on terminal rendering.
Read-only mode asks before writes and commands. Explicit approval permits the
displayed operation without changing the mode; remembered grants retain their
displayed scope. Auto mode also asks when classification cannot allow an action.

## Activity presentation

`tina/activity-tui` is included in the default plugin set. F4 or `/activity`
opens collapsible tool results, replacement previews, errors and child progress.
Enter/Tab folds, T toggles raw arguments and call details, arrows select,
Page Up/Down or the wheel scroll, and Esc/F4
closes. F4 works during execution and preserves unfinished input.

In Settings → Plugins, uncheck `tina/activity-tui` to hide tool presentation.
Choose Session for a temporary override or Workspace/Global to persist it.
Ctrl-R removes the override. Re-enabling reconstructs recent calls/results from the transcript.
An explicit `[plugins].enabled` list replaces the default set; include
`"tina/activity-tui"` there if you want this presentation.

## Providers and pools

```toml
version = 1
[default]
provider = "pool"
model = "fallback-model"
max_tokens = 8192
# reasoning_effort = "high" # opt in only for models that support it

[providers.pool]
members = ["local/org/model", "other/fallback-model"]

[providers.local]
wire = "openai" # anthropic | openai | gemini
base_url = "http://127.0.0.1:8000"
models = ["org/model|Local model"]
# api_key = "..."          # or the provider's environment variable
# auth_token = "..."       # bearer auth on Anthropic wire
requests_per_minute = 30
min_request_interval_ms = 500
max_output = 4096
# output_token_field = "max_completion_tokens" # OpenAI-compatible wire

[providers.other]
wire = "openai"
base_url = "http://127.0.0.1:8001"
models = ["fallback-model"]
disabled_models = ["retired-model"]
```

Built-in provider descriptors supply endpoints, credential-variable names and
model catalogs; custom tables can override them. Config credentials precede
environment values. A bare model reference defaults to the Anthropic wire.
Environment compatibility includes `TINA_LLM_ENDPOINT`/`TINA_LLM_TOKEN` for the
bare Anthropic path, and provider-specific `*_BASE_URL`, `*_AUTH_TOKEN` and
`*_API_KEY` variables. Secrets are masked in the settings UI.

A pool member is `provider` (uses the selected model) or `provider/model`.
Models may contain slashes. Pools cannot contain pools. Routing rotates the
starting member; a transient failure can try the remaining members once,
but never after answer text or a tool call has been published. A response that
produced only reasoning can recover once, including with a single provider.
An output-limit recovery asks for brief reasoning without changing the configured
token limit. Both attempts count toward spend limits; cancellation stops recovery.
Permanent/authentication failures stop.
Settings on each concrete member control its requests; a pool is routing only.

Request slots and start spacing are shared by provider ID across foreground
and child sessions. Provider RPM and minimum interval both apply, using the
larger interval. 429/503 Retry-After adds a cooldown capped at 60 seconds.
Cancellation removes queued requests and releases active slots. There is no
unbounded retry ladder and no cross-process scheduler.

## Limits

```toml
[limits]
max_global_tokens = 0
max_session_tokens = 0
max_turn_tokens = 0
max_request_tokens = 0
max_sub_agent_tokens = 0
max_sub_agent_depth = 3
max_sub_agent_concurrency = 3
requests_per_minute = 0
min_request_interval_ms = 0
max_concurrent_requests = 4
```

Token/rate caps default to unlimited (`0`). Depth/concurrency for subagents
use literal counts, so `0` prevents spawning. Request concurrency `0` is
unlimited; otherwise it caps each provider's concurrent requests. The global
RPM limit spaces starts across all providers in this app session.

Budgets count reported input, output, cache-read and cache-write tokens. Global
means this running app and its children, not a persistent account-wide quota.
Session spend is restored from the main transcript's completed turns; historical
child spend is not reconstructed on restart. Each child has its own token cap.
`max_request_tokens` checks approximate input size (serialized UTF-8 bytes / 4).
Turn caps reset on each user input. Caps refuse subsequent requests once spend
reaches the limit; already-running requests can overshoot, and usage missing
from a cancelled/broken transport cannot be counted. These are request admission
controls, not exact billing ceilings.

## Reasoning, output and theme

`[default]` supports `max_tokens`, `reasoning_effort` and `thinking_budget`.
Concrete provider tables may override effort/budget and set output tokens with
`max_output`. Output precedence is provider `max_output`, then the model catalog's
output limit, then `[default].max_tokens` (8192 when omitted). The default is a
fallback; it does not cap a configured provider or model value.

- Anthropic: `max_tokens`, `output_config.effort`, adaptive thinking for an
  effort setting, or an explicit thinking budget (0 disables; otherwise at
  least 1024 and less than output tokens).
A provider-level thinking choice overrides the global thinking choice as a
whole. `reasoning_effort = "auto"` means use the provider default, even when a
global thinking setting exists. The settings UI manages these keys for you.

- OpenAI-compatible Chat Completions: `reasoning_effort`, with either
  `max_tokens` or `max_completion_tokens`. The built-in OpenAI descriptor uses
  the latter. Numeric `thinking_budget` is rejected on this wire.
- Gemini: `generationConfig.maxOutputTokens` and `thinkingConfig`, accepting
  either a numeric budget or a level, not both. Effort `none` uses budget 0.

These settings do not make every model support reasoning. Choose fields and
values supported by your endpoint/model; unsupported model-specific settings
can still be refused by the server. The current OpenAI wire is Chat Completions,
not Responses. Wire vocabulary references:
[OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning),
[Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort),
[Gemini thinking](https://ai.google.dev/gemini-api/docs/generate-content/thinking).

```toml
[theme]
variant = "dark" # default | light | dark
```

`dark` and `light` paint Tina's background as well as its text; the terminal
profile can use either background. `default` inherits the terminal's colors.
Changes take effect on the next launch. Tina restores the normal terminal on
exit without changing its profile or palette.

Optional base-color overrides:

```toml
[theme.canvas]
foreground = "38;5;252"
background = "48;5;234"
```

Existing nested theme color overrides merge over the selected variant. Values
are ANSI color-number strings, never arbitrary escape sequences. Settings offers
the variant picker; custom color tables remain editable in TOML.

## Input classification

`tina/classification` is enabled by default. If `[plugins].enabled` is explicitly
listed, add that ID or check it in Settings → Plugins → Global scope.
It reports project question vs instruction, then Git operations for instructions.
Results appear in the status bar and `/classification`; they never change agent
routing or permissions. Work runs in the background and stops on cancellation,
superseding input, timeout or unload.

```toml
[typesafe]
api_key = "${TYPESAFE_API_KEY}"
model = "jev-latest"
# endpoint = "https://api.typesafe.ai/v1/systemone"
```

These keys are read by the classification plugin on each input. A nonempty saved
key wins; otherwise `TYPESAFE_API_KEY` is used. `${VARIABLE}` resolves from the
environment. No credential means unavailable classification and no HTTP request.
This uses the Typesafe judgment API independently of the conversation provider.
Requests have bounded input size and a 30-second total deadline. Their usage is
not included in conversation token spend/caps yet. Repository indexing and
Attractor remain disconnected.

## Completion

`Command.complete` is a UI-independent callback owned by the command's plugin.
The TUI queries it for slash-command arguments. Mode, plugins, plans, goals
and update commands provide suggestions; live unloading removes their commands
and completions together. Settings menus filter by typed text, and Tab completes
supported fields such as provider/model lists, plugin IDs and effort values.

For shell completion:

```sh
# bash: source generated output
source <(tina --completion bash)
# zsh: after compinit
source <(tina --completion zsh)
# fish
tina --completion fish | source
```

Shell completion covers flags, paths and shell names. It does not start the
app or query session IDs. `@` file completion remains available in the prompt.

## Plugin selection migration (0.9.6)

`[plugins] selection_version = 2` makes `enabled` the complete plugin selection.
Legacy lists without this marker retain their formerly implicit base plugins.
Saving global plugin checkboxes writes the complete selection and this marker.
Workspace and session overrides retain their precedence over global settings.
Settings explain capability dependencies before allowing a provider to be disabled.

`tina/system-instruction` replaces `tina/persona`; old enabled lists and overrides
are read using the new name. `tina/step-limit` is optional; the loop has no built-in
step ceiling. Human approval requests have no timeout by default.

# Engine2 config compatibility audit

## This machine

The actual `~/.tina/config` was read, validated by the settings editor, and used
to assemble the app in a temporary workspace. The selected model is
`zai-coding-plan/glm-5.3-flashx`. Offline HTTP capture verified that each of the
eight configured providers constructs requests with its configured credential
and model. No provider request was sent, no credential value was printed, and
the config was not changed. This verifies configuration/wire construction,
not whether a provider currently accepts a key or serves the selected model.

The earlier engine2 reader rejected this file: `zai-coding-plan` and `xiaomi`
were discovered providers, absent from the compiled catalog, with no explicit
`base_url` in config. Startup now reads the existing
`~/.tina/cache/models.dev.providers.json` cache offline. Supported OpenAI-wire
providers supply their endpoint, model metadata and credential-variable names;
compiled provider definitions win collisions. Config overrides win over both.
Explicit model entries extend the descriptor catalog. No cache refresh is
performed; a new machine needs the cache or explicit `base_url`/`wire` settings.
`COCOON_MODELS_DEV=0` disables this compatibility input. Corrupt cache rows and
unsupported wire packages are skipped; a configured provider with neither a
usable cached definition nor a URL is an error, not silently ignored.

Exactly 28 keys in the inspected file are consumed:

| Location | Keys present and consumed |
| --- | --- |
| Top level | `version` |
| `default` | `provider`, `model` |
| `providers.deepseek` | `api_key`, `disabled_models` |
| `providers.nim` | `api_key`, `disabled_models` |
| `providers.novita` | `api_key`, `disabled_models` |
| `providers.openrouter` | `api_key`, `disabled_models` |
| `providers.thinkingmachines` | `api_key`, `base_url`, `disabled_models` |
| `providers.hetzner` | `api_key`, `disabled_models` |
| `providers.zai-coding-plan` | `api_key`, `disabled_models`, `models` |
| `providers.xiaomi` | `api_key`, `disabled_models` |
| `limits` | `max_global_tokens`, `max_sub_agent_tokens`, `requests_per_minute`, `max_turn_tokens`, `max_session_tokens`, `max_request_tokens` |
| `theme` | `variant` |

The only ignored key present is **`typesafe.api_key`**. Classification/index
remain disconnected. All eight provider credentials currently come directly
from config, so environment keys do not override them.

| Provider | Fallback API-key variables, in priority order |
| --- | --- |
| deepseek | `DEEPSEEK_API_KEY` |
| nim | `NVIDIA_API_KEY`, `NIM_API_KEY` |
| novita | `NOVITA_API_KEY` |
| openrouter | `OPENROUTER_API_KEY` |
| thinkingmachines | `THINKINGMACHINES_API_KEY` |
| hetzner | `HETZNER_API_KEY` |
| zai-coding-plan | `ZHIPU_API_KEY`, `ZAI_CODING_PLAN_API_KEY`, `ZAI-CODING-PLAN_API_KEY` |
| xiaomi | `XIAOMI_API_KEY` |

Reproduce this audit offline (output includes key names, never key values):

```sh
cd packages/tina_tui
dart run tool/verify_local_config.dart
# An explicit config path can be supplied as the sole argument.
```

## Complete reader surface

| Table | Consumed keys |
| --- | --- |
| Top level | `version` (absent or `1`) |
| `default` | `provider`, `model`, `max_tokens`, `reasoning_effort`, `thinking_budget` |
| `providers.<id>` | `name`, `wire`, `base_url`, `api_key`, `auth_token`, `models`, `disabled_models`, `members`, `requests_per_minute`, `min_request_interval_ms`, `max_output`, `reasoning_effort`, `thinking_budget`, `output_token_field` |
| `limits` | `max_global_tokens`, `max_session_tokens`, `max_turn_tokens`, `max_request_tokens`, `max_sub_agent_tokens`, `max_sub_agent_depth`, `max_sub_agent_concurrency`, `requests_per_minute`, `min_request_interval_ms`, `max_concurrent_requests` |
| `plugins` | `enabled`, `approval_channel`, `overrides` (plugin ID → boolean) |
| `theme` | `variant`, plus the color fields below |
| `theme.chat` | `user_bar`, `user_text`, `agent_text`, `dim`, `cyan`, `green`, `yellow`, `red`, `header`, `inline_code`, `code_block`, `link` |
| `theme.border` | `focus`, `selection` |
| `theme.border.busy` | `rail`, `head` |
| `theme.menu` | `bar_highlight`, `bar_dim`, `dropdown_selected`, `dropdown_disabled` |
| `theme.completion` | `dim`, `selected` |
| `theme.dialog` | `confirm` |
| `theme.info_panel`, `theme.spinner`, `theme.line_editor` | `dim` |
| `theme.text_panel` | `focused`, `unfocused` |
| `theme.host_message` | `normal`, `dim`, `user`, `warning`, `error`, `success` |

Theme color values must be ANSI-number strings. Console-only RGB arrays and
numeric `tail_length` are not supported by this config reader: they fail its
validation rather than being silently honored.

Other top-level tables and unknown fields under `default`, `providers` and
`limits` are ignored at runtime and preserved by settings saves. This includes
legacy `default.workflow`, `prompts`, `trust`, `regions`, `sessions`,
`environment`, `tui`, `permissions`, `typesafe` and `index`. In particular,
`sessions.jsonl.root` does not choose the new SQLite path (use `--store`), and
`permissions.mode` does not set engine2's mode (use `/mode`). Unknown keys in
`plugins` are rejected. Unknown theme colors have no display effect but are
still subject to theme value validation.

Global config defaults to `$HOME/.tina/config`; `--config` selects another file.
Workspace `<cwd>/.tina/config` supplies only `plugins.overrides` and
`plugins.approval_channel`, not provider/model/credential overrides.

For an app-created provider, credential precedence is: nonempty config
`auth_token`, config `api_key`, `TINA_LLM_TOKEN` (Anthropic only),
`<PREFIX>_AUTH_TOKEN`, descriptor API-key variables in order, `<PREFIX>_API_KEY`,
then legacy `<UPPERCASE_ID>_API_KEY`. Prefixes uppercase IDs and replace hyphens
and other punctuation with underscores. Endpoint precedence is config
`base_url`, `<PREFIX>_BASE_URL`, `TINA_LLM_ENDPOINT` (Anthropic only), then the
descriptor endpoint. Empty credential environment values are skipped.

Compiled aliases include `XAI_API_KEY` for grok, `NVIDIA_API_KEY` for nim and
`QWEN_API_KEY` for qwencloud. Other built-ins use their named API-key variables;
Anthropic additionally supports `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY`.
The reader does **not** expand `$VAR`, `${VAR}` or `env:VAR` inside TOML strings;
those are literal values. Set the real environment variable and omit the
corresponding config credential to use environment lookup.

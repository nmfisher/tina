# Reasoning controls and empty answers

For GLM-5.3 / GLM-5.3-Flash, retry a reasoning-only failure with:

```sh
tina --continue --reasoning-effort low
```

To keep this preference, set it alongside the configured provider/model in
`~/.tina/config`:

```toml
[default]
provider = "glm"
model = "glm-5.3-flash"
reasoning_effort = "low"
```

Keep your existing provider ID and endpoint, including Coding Plan credentials.
The CLI setting overrides the file; `--reasoning-effort auto` leaves the wire
parameter unset, restoring the provider/model default. These are launch settings.
They apply to the configured provider's conversations, restored conversations,
workflow nodes, and delegated agents; a different provider keeps its own defaults.
A configured pool passes the setting to every member. Use compatible members.

Tina sends `reasoning_effort` as an OpenAI-compatible request parameter, separately
from messages and tool schemas. It does not rewrite prompts or tool declarations.
The endpoint/model must support the requested value. Native Anthropic/Gemini wire
adapters reject this setting rather than silently ignoring it.

[Z.AI's documented behavior](https://docs.z.ai/guides/capabilities/thinking):
GLM-5.3 and GLM-5.3-Flash require thinking and accept `low`, `high`, and `max`.
Their default is `max`; sending `thinking.type = "disabled"` is an error.
Effort is a qualitative control, not an exact reasoning-token budget or a
reservation of tokens for an answer. Even `low` can fail on a difficult task.
Split the task or switch models if that happens.

`--max-output-tokens` caps one response's output, including reasoning and answer
tokens. `--max-tokens` remains a compatibility alias; if both are provided, the
last value wins. The default remains 32,768 tokens.
Tina clamps it to the catalog's output ceiling when one is known. Requesting
200k therefore does not necessarily send a 200k cap. The per-turn spend limit
(`--max-turn-tokens`) is a separate guard over repeated requests and their input
and output tokens; increasing it does not increase a response's output cap.

When `reasoning_content` arrives, Tina shows a single `▸ Reasoning (collapsed)`
row per provider attempt. The full text is retained as structured local transcript
metadata, separate from answer content. Rows are collapsed on session restore too.
Expansion controls are a future UI feature; the data needed to expand is saved.

Completed, failed, and cancelled requests retain the reasoning received so far;
truncated/interrupted blocks are marked partial. A hard process kill before the
request settles can still lose that in-flight block. Reasoning follows the same
history retention/compaction policy as other transcript entries. It is excluded
from subsequent API requests and input-token estimates.

Completed responses retain diagnostic metadata: the effective cap sent, whether reasoning was observed, and a reasoning
token count only when the provider reports one. Reasoning tokens are already
included in output usage and are never counted again as additional spend.

A completed response with reasoning but no answer/tool call stops with an
actionable diagnosis, including when the endpoint says `stop` instead of `length`.
Neither the pool nor the agent resends that same completed reasoning-only request.
Ordinary transient empty responses retain bounded retry recovery. Reasoning-only
responses are saved as local transcript records, never sent as empty assistant API
messages or treated as successful work.

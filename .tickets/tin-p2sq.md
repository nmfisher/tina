---
id: tin-p2sq
status: closed
deps: []
links: []
created: 2026-08-15T00:00:00Z
closed: 2026-08-16T19:40:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tools, bash, escaping, crash]
---
# FormatException: Unterminated string when an agent runs a quote-heavy shell one-liner

## Context

Headless/read-only session (model deepseek-v4-flash). User asked: "what tests do we have?"

The agent's tool calls so far:

- `glob: **/*test*` → ok
- `glob: **/test/**` → ok

Then the agent attempted a shell command — a complex one-liner with embedded quotes and backslash escapes (a `for ... done; echo ...` loop piping through `2>/dev/null | wc -l | tr -d ' '` with escaped quotes around its echo strings) — and tina threw:

```
error: FormatException: Unterminated string (at character 349)
```

The error fragment shows the command text mid-escape (truncated at the quote boundary), e.g. `... 2>/dev/null | wc -l | tr -d ' '); echo "Sd: -Sn\"; done; echo,` — i.e. the model's command contains double quotes AND backslash-escaped quotes.

## Likely cause

A Dart string built from the model's command text becomes invalid when the command contains unescaped/escaped quotes — the string literal terminates early (character 349) and parsing throws `FormatException: Unterminated string`. Suspects:

- The Bash tool's command assembly (wrapping the command for `bash -c` and/or quoting it) without escaping embedded quotes.
- A JSON encode/decode of the tool call payload when the command text contains quotes + backslashes (the model emitting `\"` inside a JSON string).

## Repro sketch

Have an agent run a command containing both kinds of quotes in one line, e.g.:

```
for f in $(glob ...); do echo "file: $f"; done; echo "done: \"$?\""
```

or anything with `\"` and `"` mixed. Expect the FormatException instead of the command running.

## Acceptance criteria (for the fix run — not started)

- Find the exact throw site (which string is being parsed at character 349).
- Fix the escaping in the tool call path so quote-heavy commands run as the model intended.
- Add a regression test with a nested-quotes one-liner.
- Existing tool tests keep passing; dart analyze clean.

Ticket only — no sandbox run requested.

## Findings and fix (2026-08-16)

### Throw site

`openai_compatible.dart` — the **accumulated `tool_calls[].function.arguments`
JSON string** assembled from the SSE deltas, decoded after the stream ends
(the line numbered 224 pre-fix). Not the Bash tool: `BashTool` passes the
command as an argv element (`['-c', command]`, bash_tool.dart:261), so there
is no shell-string assembly anywhere in the tool path and nothing to escape.
The model itself streamed invalid JSON — an unescaped `"` inside the command
value of a long one-liner.

The adapter already wrapped that decode in the stream try/catch (a prior
regression guard), so it yielded a `StreamError` instead of throwing. The
remaining defect was one level up: `Agent.run` treats any `outcome.error` as
fatal — it printed `\nerror: FormatException: Unterminated string (at
character N)\n` (agent.dart:150, the "error: " prefix from the ticket) and
aborted the whole turn, discarding text that had already streamed.

### Fix

A malformed-arguments failure is now recovered **per call** instead of
killing the response:

- `ToolUseBlock` carries an optional `argumentsParseError`
  (message.dart; serialized as `arguments_parse_error`, round-trips through
  the session store).
- Both streaming adapters decode per call and set that field on
  `FormatException` instead of failing the stream: the OpenAI-compatible
  post-loop assembly and Anthropic's `_ToolUseBuilder.build()` (which was a
  bare `jsonDecode` before). Gemini needs nothing — its wire delivers args
  pre-parsed.
- `Agent.run` answers such a call with an error `ToolResultBlock` whose text
  names the parse error and tells the model how to re-emit the call
  (`\"` / `\\`), then continues the step loop — the same shape as the
  existing unknown-tool branch. The tool never runs with garbage input.

Quote-heavy commands that the model *does* escape correctly were never
broken and still decode verbatim (pinned by a test with
`for f in *; do echo "file: $f"; done; echo "done: \"$?\""`).

### Verification

- Tests: 2 adapter tests + 2 agent tests (turn survives, tool not executed,
  error result fed back, a good retry after a bad call runs with input
  verbatim). tina_engine 540 green, root suite 540 green. `dart analyze`
  unchanged (2 pre-existing warnings in untouched files).
- Live, `tool/stub/scenarios/malformed_tool_call.txt` (new, deterministic
  replay of the ticket's shape) via `dart run bin/tina.dart --prompt`:
  - pre-fix (stashed): `error: FormatException: Unexpected character (at
    character 97)` and the turn dies — the ticket's symptom.
  - post-fix: notice `bash: malformed arguments — asking the model to
    retry`, the model's retry `read` executes (`ok`), the turn completes in
    text.

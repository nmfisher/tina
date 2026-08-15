---
id: tin-p2sq
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
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

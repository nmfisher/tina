# Stub LLM provider server

A small local HTTP server that plays the role of the LLM provider: it
replays canned OpenAI-compatible SSE responses so tina runs
deterministically — zero spend, no real model, no tina code changes. It
speaks the same wire as `OpenAiCompatibleAdapter`
(`packages/tina_engine/lib/src/llm/openai_compatible.dart`), i.e. the
`api.deepseek.com` `/v1/chat/completions` SSE shape.

Part of the UI sweep loop (`docs/ui-sweep-loop.md`, provider mode 2).

## Run it

```sh
dart run tool/stub_server.dart --scenario normal           # default port 8787
dart run tool/stub_server.dart --scenario emoji_cjk --port 8901
```

Flags: `--scenario <name>` (a file in `tool/stub/scenarios/`, no `.txt`),
`--host`, `--port`, `--dir <scenarios-dir>` (used by the test to point at
the repo's scenario files), `--help`.

The server logs each request to stdout: scenario, turn number, step served,
status, bytes in, lines out. `GET /healthz` is a liveness probe;
`POST /__reset` rewinds the step counter to 1 between sweep tasks.

## Point tina at it

`~/.tina/config` (chmod 600) — a custom provider id whose `base_url` is the
stub:

```toml
version = 1

[default]
provider = "stub"
model    = "stub-1"        # any id; the stub ignores the request body

[providers.stub]
api_key  = "stub-key"      # required: tina errors on a provider with no key
base_url = "http://127.0.0.1:8787"
wire     = "openai"
```

Then run tina as usual — headless smoke test:

```sh
dart run bin/tina.dart --prompt "What does EventBus.publish do when a subscriber publishes during dispatch?"
```

The answer is whatever the scenario script canned; the same scenario + same
request produces identical bytes every run.

## Scenarios

| Name | What it replays |
|------|-----------------|
| `normal` | plain streaming turn: text deltas, finish, usage, `[DONE]` |
| `abort_midstream` | three deltas, then the connection is destroyed mid-tokens — no finish frame, no `[DONE]`; step 2 is a clean retry turn |
| `long_line` | one 48 KiB token with no break, plus a single ~7 KiB word line |
| `emoji_cjk` | CJK, wide chars, ZWJ sequences, skin tones, flags, CJK punctuation |
| `rapid_tool_calls` | three `tool_use` blocks back to back (`read`/`read`/`grep`), then a follow-up answer turn |
| `empty` | well-formed stream with no content at all |
| `error` | immediate HTTP 400 with an OpenAI-style error body |

## Writing a new scenario

A scenario is a plain text file, `tool/stub/scenarios/<name>.txt`. Every
non-directive line is sent on the wire **verbatim** (plus a trailing
newline) — normally `data: {...}` SSE frames and blank separators. The
server injects nothing, so replay bytes are exactly the file's bytes.

Directives (a directive must be the whole line):

- `# ...` — comment, not sent.
- `!step` — starts the next step. Steps map to requests in order: request 1
  gets step 1, request 2 gets step 2, and so on (a multi-turn tool-call
  flow is one file). Requests past the last step replay the last step.
- `!status <code>` — respond with this HTTP status instead of 200; the
  step's lines become the literal error body. Use a non-retryable code
  (400) — tina retries 5xx/429 with *jittered* backoff, so those turns are
  deterministic in bytes but not in timing.
- `!delay <ms>` — pause before the following lines (pacing only).
- `!abort` — destroy the socket at this point. The response ends mid-tokens
  with no finish frame and no `[DONE]` (an HTTP client without a
  content-length reads this as a stream that stopped early).

Frame skeleton for a text delta (tina reads `choices[0].delta.content`,
`choices[0].finish_reason`, and any frame's `usage`):

```
data: {"choices":[{"index":0,"delta":{"content":"hello "},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

data: [DONE]
```

For tool calls, stream `delta.tool_calls` entries with a stable `index`,
the `id`/`function.name` on the first fragment, `function.arguments`
(JSON-encoded string) after, and `"finish_reason":"tool_calls"` at the end —
see `rapid_tool_calls.txt`. Use tina's real tool names (`read`, `grep`,
`bash`, `edit`, `write`, ...) so the tool phase runs for real.

Keep committed scenario files byte-stable: never regenerate or reformat
one that a ticket references (`repro: scenario X step 2` must mean the same
bytes forever).

## Replayable repros with workspace snapshots

The sweep brief: *snapshot + same stub script = fully replayable repro*.

1. Start the stub with the scenario the bug was found with.
2. Reproduce in tina (tmux harness per `docs/ui-sweep-loop.md`).
3. `tool/example_workspace.sh snapshot <ticket-id>` **before** fixing
   anything (captures agent-made edits, untracked files, half-finished
   state).
4. Fix, close the ticket per the normal criteria.
5. `tool/example_workspace.sh restore <ticket-id>`, restart the stub
   (`POST /__reset` so it is back at step 1), replay the same prompt at the
   same geometry — the identical agent actions and stream bytes must
   reproduce the original screen or prove the fix.
6. `tool/example_workspace.sh reset` before the next scenario.

Determinism guarantee: the server adds no timestamps, ids, or jitter to the
response body — the SSE payload is the scenario file's bytes, so two runs
of the same scenario are byte-identical (see
`test/tools/stub_server_test.dart`, which asserts exactly that, twice).

## Tests

```sh
dart test test/tools/stub_server_test.dart   # server only
dart test                                    # whole suite (server test included)
```

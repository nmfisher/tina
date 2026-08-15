---
id: tin-vb4k
status: closed
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [harness, stub, provider, testing]
---
# Stub LLM provider server for deterministic sweeps

## Context

The UI sweep loop (docs/ui-sweep-loop.md) needs a local stub server that plays the role of the LLM provider: it replays canned OpenAI-compatible SSE responses so tina runs deterministically, with zero spend and no real model. Referenced in the brief: "A local stub server replaying canned SSE over the provider base_url override — deterministic replays of mid-stream aborts, very long lines, emoji/CJK, rapid tool calls. Zero tina code changes needed. Bugs found against the stub are replayable forever." Also in tool/sweep_tasks.md: "With the stub provider the agent's actions are deterministic, so a snapshot + the same stub script is a fully replayable repro."

It does NOT exist yet — tool/ has no stub server or scenario scripts. Build it.

## Scope

- A small local HTTP server (dart:io, no heavy deps) that speaks the same wire format tina already uses for OpenAI-compatible providers (the built-in deepseek descriptor wire — api.deepseek.com style /chat/completions SSE). tina connects via the provider base_url override; no tina code changes.
- Scenario scripts drive the responses. Each scenario = a file that describes the canned SSE event stream (or the exact bytes) for a request.
- Scenarios needed at minimum:
  - normal streaming turn (text deltas, done)
  - mid-stream abort (connection cut / error event mid-tokens)
  - very long line (huge single token chunk)
  - emoji/CJK content
  - rapid tool calls (several tool_use blocks back to back)
  - empty response / immediate error
- Determinism: same scenario + same request → identical bytes, every run.
- Lives under tool/ (per the brief: scripts go in tool/). Document how to run it and how to point tina at it (base_url override in ~/.tina/config).

## Acceptance criteria

- Server runs with a scenario selector (e.g. dart run tool/stub_server.dart --scenario <name>).
- tina --prompt against the stub (base_url override) completes a canned turn deterministically.
- Each scenario replays byte-identical on repeat runs.
- A short README or doc comment: how to start it, how to write a new scenario, how to use it with example_workspace.sh snapshots for replayable repros.
- dart analyze clean; existing tests keep passing.

Container notes: tk is not installed (edit ticket frontmatter + Result section instead); git push is blocked for agents (mirror via the GitHub git data API, then git reset --hard to the remote commit).

## Progress

2026-08-15 — started. Branch `asb/stub-server`. Plan: `tool/stub_server.dart` (dart:io HTTP server, raw-SSE scenario scripts under `tool/stub/scenarios/`), a test under `test/tools/`, and a README. No tina code changes.

## Result

2026-08-15 — done, status closed. Zero tina code changes (one pointer line added to `tool/sweep_tasks.md`, a doc).

Shipped:

- `tool/stub_server.dart` — scenario selector CLI (`--scenario <name>`, `--host`, `--port`, `--dir`), a scenario-script parser, and the server. Built on a raw `ServerSocket` speaking just enough HTTP/1.1 by hand, not `HttpServer`: `HttpResponse.write` is latin1 (would mangle the emoji/CJK scenarios) and `detachSocket` refuses after headers are flushed, which blocks a true mid-stream `!abort`. Each response is sent with `connection: close`; the step counter advances per request and `POST /__reset` rewinds it. `GET /healthz` is a liveness probe.
- `tool/stub/scenarios/*.txt` — all seven required scenarios: `normal`, `abort_midstream`, `long_line` (one 48 KiB token + a ~7 KiB single word line), `emoji_cjk`, `rapid_tool_calls` (three back-to-back `read`/`read`/`grep` calls with tina's real tool names + a follow-up answer step), `empty`, `error` (HTTP 400 — deliberate: tina retries 5xx/429 with *jittered* backoff, 400 fails at once and deterministically).
- Script format: every non-directive line goes on the wire verbatim; directives are `#` comment, `!step` (per-request steps), `!status <code>`, `!delay <ms>` (pacing only), `!abort` (destroy the connection mid-tokens). The server injects nothing, so same scenario → identical bytes.
- `tool/stub/README.md` — how to run, the exact `~/.tina/config` `[providers.stub]` block (needs `api_key`; tina errors on a keyless provider), how to write a scenario, and the snapshot workflow with `tool/example_workspace.sh`.
- `test/tools/stub_server_test.dart` — 7 tests: scenario inventory, complete-turn shape, byte-identical replay (two serves compared), 400 error body, abort truncation (deltas but no finish frame/[DONE]), three tool_use blocks, step advance/tail-repeat.

Verified:

- `tina --prompt` round-trips the stub through the `base_url` override (`HOME` pointed at a scratch dir; the real `~/.tina/config` is read-only here and was left untouched — one accidental first run used the real provider before that was noticed). All of `normal`, `abort_midstream`, `emoji_cjk`, `empty`, `error`, `rapid_tool_calls`, `long_line` exercised end-to-end; the error surfaces humanized (`Stub 400 (invalid_request_error)`), rapid tool calls run the real read tool (grep auto-denies headless, as designed), abort ends the turn from the partial deltas.
- New test file: 7/7 pass. Root suite: 513 pass, 1 fail — `session_controller_test.dart` "user message survives quitting before the response completes" fails identically on the clean tree (verified via `git stash`), pre-existing, not this change.
- `dart analyze` on the new files: clean. Repo-wide analyze is NOT clean on this branch or on main: 32 pre-existing errors (`tool/render_to_image.dart` + `tool/visual_test.dart` import non-existent `tina_console/src/panel_layout.dart`/`panel_renderer.dart`; `packages/tina_console` tests use `package:fake_async` which is not a dependency). Filed separately, out of scope here.
- Environment notes for whoever runs this next: the container has no Dart 3.12 (`pubspec` needs `^3.12.0`, flutter's dart is 3.11) — one was unpacked to `/tmp/dart-sdk`. The `dart_notcurses` submodule was cloned from the remote and pinned to `eab3111` (per the gitlink), plus a local `libunistring.so` symlink into `native/lib/linux_arm64` (only `libunistring.so.5` ships; no sudo) so the native build hook links. Both are local-only state.

`abort_midstream` semantics, pinned deliberately: the cut is a connection destroy after flushed deltas — no finish frame, no `[DONE]`. tina completes the turn from the partial content rather than raising a StreamError (dart's HTTP client reads a content-length-less body ending as EOF). A hard RST variant (SO_LINGER 0) was tried and did not change what the client sees, so it was dropped.

Process: update the ticket when starting and when done. Commit all work locally. Push to the branch. Raise a PR when finished. Never merge. Simplified technical English.

---
id: tin-vb4k
status: open
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

Process: update the ticket when starting and when done. Commit all work locally. Push to the branch. Raise a PR when finished. Never merge. Simplified technical English.

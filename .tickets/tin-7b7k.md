---
id: tin-7b7k
status: open
deps: [tin-k7f2]
links: [tin-3i3l]
created: 2026-09-26
type: proposal
priority: 3
assignee: Nick Fisher
tags: [architecture, terminal, pty, process, audit]
---

# Interface decoupling audit — non-TUI front ends + engine terminal placement

## Context

Architecture review answering one question: can an interface outside the
terminal (web, Signal, Telegram, WhatsApp) attach to tina without rewriting
the core? Full inventory (16 surfaces, file:line anchored), findings, and
recommendations: `docs/proposals/interface_decoupling_audit.md`.

The audit's two-part answer:

- **The seams are real.** `HostInterface` (engine, 3 implementations),
  `AgentSink`/`AgentEventBus`, `CommandRegistry.dispatch` (takes the host
  interface, no UI types), `InputRoutes` (strings, not key events),
  `TurnExecutor` (pure Dart), `SessionStore`/`SessionIndex`. Headless is the
  proof these seams work: it mounts the same command contributions the TUI
  does. A web or bot front end is one more `HostInterface` implementation,
  not a protocol invention.
- **Three gaps block it**, and they are the same three tin-3i3l found from
  the approvals side: every interactive asker is TUI-shaped (key reads,
  overlays, editors); the null-asker paths auto-answer (workflow gates
  auto-yes, ask_user auto-first-option — fail-open); no open ask survives
  the process. tin-3i3l steps 1–3 are the prerequisite; this audit does not
  re-specify them.

Engine-side findings unique to this audit:

- **PTY stack with no consumer.** `packages/tina_engine/lib/src/terminal/`
  (C shim, FFI bindings, worker-isolate runner, 38 tests; landed `a3f008e`
  for the shell panel) has zero importers, is not exported from the engine
  barrel, and its only documented use imports it by internal `src/` path
  (`docs/features/pty_backend.md:25`). The intended consumer is specced for
  the root package, i.e. root → engine-src — the shape the architecture
  policy has to exempt.
- **Build deps ride along.** `code_assets`/`hooks`/`native_toolchain_c`
  are build-time-only but sit in the engine's `dependencies`
  (`pubspec.yaml:11-14`), so every consumer's lockfile carries the native
  toolchain for a PTY it cannot use.
- **Process registry is host machinery.** `ChildProcessRegistry` +
  `process_tree.dart` (reap-on-exit) serve the engine's process runner, the
  PTY runner, and root's exit funnel — not engine- or terminal-specific.

Verdicts: web + Signal/Telegram/WhatsApp bots **feasible** on the tin-3i3l
daemon recipe (`tina serve` = one `HostInterface` impl + transport); wasm/
browser and Cloudflare Workers **not this seam** — the engine has `dart:io`
in 44 files; those are re-platforms, and the `spikes/dart_wasm_worker`
spike already frames them honestly.

## Proposal

Documentation only in this ticket; four follow-up recommendations, each a
separate code change:

1. **Second front end = new capabilities, not a new layer.** Reuse
   `CommandRegistry.dispatch` + `InputRoutes`; supply a new
   `CommandContext`/`FrontendCapabilities` implementation; never wire a
   transport through `TuiCoordinator`.
2. **Extract the process seam** (`process_registry.dart` +
   `process_tree.dart`) into a small `tina_process` package —
   opportunistically, alongside the PTY move or first daemon work.
3. **Park the PTY stack** until the terminal panel lands; then either a
   recorded baseline exception for the root→engine-src edge or a
   `tina_pty` package (the one-way dependency arrow already suggests the
   latter).
4. **Move the three build deps out of `dependencies`** when the PTY
   question settles — standalone, trivial.

Plus one policy note: the advisory session lock means one live front end
per session; document it as a decision.

## Acceptance

- The acceptance list in
  `docs/proposals/interface_decoupling_audit.md` is the contract.
- Headline items: a served session's asks park rather than auto-answer;
  `/help`, `/sessions`, `/model`, `/permissions` dispatch identically from
  a served front end and the TUI; UI-only commands report "not available on
  this front end" instead of no-op; after recommendation 4 the engine's
  `dependencies` contain no `code_assets`/`hooks`/`native_toolchain_c` and
  `dart run tool/check_architecture.dart` + `dart test test/architecture/`
  stay green.

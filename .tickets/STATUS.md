# Sweep status
Now:     Interface decoupling audit (tin-7b7k) filed: can a non-TUI
         front end (web, Signal, Telegram, WhatsApp) attach without
         rewriting the core? Verdict: seams are real — HostInterface
         (3 impls), AgentSink/AgentEventBus, CommandRegistry.dispatch,
         InputRoutes, TurnExecutor, SessionStore/SessionIndex — so a
         second front end is one more host implementation, not a
         protocol. Three gaps block it, same three tin-3i3l found:
         askers are TUI-shaped, null-asker paths auto-answer, no ask
         survives the process. Engine-side finds: PTY stack
         (lib/src/terminal/, a3f008e) has zero importers and its only
         documented use imports by src/ path; code_assets/hooks/
         native_toolchain_c are build-only but ride in dependencies;
         ChildProcessRegistry is host machinery. Web + bots feasible
         after tin-3i3l 1–3; wasm/browser not this seam (dart:io in 44
         engine files). Proposal:
         docs/proposals/interface_decoupling_audit.md.
Next:    Owner call on ordering: tin-3i3l steps 1–3 (provenance,
         AskStore, answer commands) are standalone and unblock remote
         answering AND the tin-7b7k front ends; steps 4–5 fold into
         plugin_posture_door.md (answerability and fail-closed gates
         are posture concerns). tin-7b7k follow-ups: build-deps move
         (trivial, standalone), process-seam extraction (with PTY or
         daemon work), PTY parked until the panel lands. Then the
         carried-over queue: tin-p4wm item 3 (`/spawn`+`/branch`
         drop configured static rules), then tin-w7dr (needs the live
         wheel repro). tin-r6km resumes at proposal P6–P8 + the PR #49
         review fixes (P0–P5 review items 1–3 and 5–7 remain open on
         main).
Blocked: tin-r6km P8 is blocked on the review fixes; nothing else.
Ask:     tin-p4wm item 2 needs a posture decision: declaring
         `explore_project` a project read flips its default ask → allow.
         Also: greenlight tin-3i3l steps 1–3 ahead of / alongside the
         posture door.
Last checkpoint: 2026-09-26 — interface decoupling audit (tin-7b7k)
         filed; ticket + STATUS updated. Previous (2026-09-25):
         approval-surface review reworded (tin-3i3l); proposal filed
         (tin-n8vq refresh before that).

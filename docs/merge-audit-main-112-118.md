# Merge audit: main v0.9.111 → v0.9.118 vs the plugin-registry stack

Prepared for PR #87's integration merge on `codex/integration-main-118`
(cut from `codex/issue85-plugin-registry` @ `18d210d1`).

- **Stack side**: `18d210d1` (engine artifact + six catalog plugins ported
  to the wasm engine). The stack forked from main at `f2c84da0`; it
  changed **210 files** since the fork — almost all of them NEW
  libraries (`tina_plugin_registry` (since promoted to owned), `tina_tui_spike` (since moved to spikes/),
  `tina_wasm` growth, `tools/plugin-registry` in Rust) plus seams in
  `apps/tina_cli`, `tina_console`, `tina_tools`, `tina_host`.
- **Main side**: `6cb9b6aa` (v0.9.111) → `5c4ec7d4` (v0.9.118), 17
  commits, ~7 releases: exact command approvals + tool path review,
  command-list approvals, drag-to-copy selection, paged resume, auto-mode
  review changes, release infra.
- **Real overlap**: only **12 files** changed on both sides since the
  fork (listed below). The large PR-#87 conflict count comes from the
  stack's 210 new/changed files meeting main's moved baselines, not from
  feature collision. The semantic overlap is concentrated in four seams.

## Per-commit classification

| commit | feature | class | evidence / resolution |
|---|---|---|---|
| `1cef7475` | Paged resumed transcripts; auto-mode host-execution review | **GENUINELY NEW** | `chat_tui.dart`/`connection_chat.dart` paging (stack untouched); `tina_mode`/`tina_tools` host review is main's model — the stack never modified `tina_mode` or these `tina_tools` files. Merge as-is; `region.dart`, `session_observation.dart` additions are additive. |
| `8aac7acd` | Release smoke alignment | **RELEASE/INFRA** | `tool/smoke_*.py` only. Keep main's. |
| `fb079cb2` | Auto-approval history bound | **GENUINELY NEW** | `tina_mode` settings; orthogonal. |
| `d51ceb8d` | Preserve added models (providers panel) | **GENUINELY NEW** | `tina_tui/providers_panel.dart`; the stack changed other `tina_tui` files, no overlap. |
| `ed3a0677` | "Where permission prompts appear" docs | **GENUINELY NEW** | Small textual conflict in `plugin_settings.dart` (stack's `skippedPluginIds` block vs a one-line label fix) — union both. |
| `765bddef` | Command formatting + scoped prefix approvals | **CONFLICTING-BY-DESIGN at the seam; machinery is GENUINELY NEW** | New `tina_tools` machinery (`command_prefix.dart`, `command_approval_store.dart`, `execution_settings.dart`), `classification/tool_call_format.dart`, `capability_envelope.dart` rework. The stack never edited these files; the design collision is approvals-model-level (below) plus the shared seams `tools_plugin.dart`/`plugin_catalog.dart`. Decision D1. |
| `537dd8e9` | Remove auto-mode end-of-turn summaries | **GENUINELY NEW** | `tina_mode` only. |
| `dc9631aa` | Scroll-shortcut docs (help) | **GENUINELY NEW** | 2-line addition to `assembly.dart` near stack changes — union. |
| `ae3061aa` | Scroll shortcuts in the status bar | **GENUINELY NEW** | `chat_tui.dart` only. |
| `fb138eb3` | Drag-to-copy selection with edge scrolling | **GENUINELY NEW** | New `tina_console/mouse_selection.dart` + input parser/backend/`input_event` work. The stack did NOT touch `input_parser.dart`/`input_event.dart` — clean add. Textual conflicts in `input_log.dart`, `line_editor.dart`, `tina_console.dart` — union. `dart_notcurses` submodule pointer moved by main only — keep main's. |
| `b2a4fee6`, `e60590ef`, `0ab64f44` | Releases 114/113/112 | **RELEASE/INFRA** | version bumps. Keep main's. |
| `a6844ac5` | Terminal smoke expectations + v0.9.115 | **RELEASE/INFRA** | keep main's. |
| `c2eb97d4` | Command-list approvals; input history reset | **GENUINELY NEW** | `command_prefix.dart` evolution + `line_editor.dart` history reset (textual conflict — union). |
| `3e7f649b` | Exact command approvals + tool path review | **CONFLICTING-BY-DESIGN at the seam; machinery GENUINELY NEW** | `command_exact.dart`, approval-store evolution, `tool_call_format` path review. Same decision D1. **Plus one hard incompatibility the merge must fix**: see "Store-shape break". |
| `5c4ec7d4` | Classification path dependency + v0.9.118 | **RELEASE/INFRA** | keep main's `pubspec`/policy wiring; verify workspace still solves with the stack's packages present. |

**SAME-FEATURE-OURS-SUPERSEDES / THEIRS-SUPERSEDES: none.** After
reading both sides: the stack and main did not independently build the
same feature anywhere. The stack built the wasm/registry/capability
axis; main built native approvals/TUI polish. Where the same FILE is
touched, the changes are complementary seams, not competing
implementations — resolved by union, with two adaptations below.

## The approvals reconciliation (decision D1 — needs Nick)

**Where the models agree.** Both sides replaced "prompt every time" with
reviewed standing grants, both persist them as JSON the user can inspect
(main: `approvals/commands.json`, `approvals/permissions.json`; stack:
the same files, compiled into a capability document), and both trace a
grant to its origin for auditability.

**Where they differ — by layer, not by contradiction.**
- **Main's model** (`command_prefix` / `command_exact` /
  `execution_settings` / mode review): native prompt-response memory.
  Grants are accumulated per command/prefix/exact-args and consulted
  live by `tina_tools` before each execution; the auto-mode judge
  reviews what grants do not cover.
- **Stack's model** (capability document, its compiler since removed): a
  COMPILED PROJECTION of the same stores for the wasm boundary. The
  compiler's doc says it outright: "command rules traced to their grant
  ids — the caller maps the approvals stores into these." Native boot
  seeds the sandbox from the document (`tools_plugin.dart`:
  read/write directories, protected paths); the wasm host enforces the
  whole document at the mediators. The registry consent flow
  (`tina_plugin_registry`) is a third, orthogonal axis: plugin
  ADMISSION capabilities, not command approval.

So the two models were designed to compose: main's stores are the
source of truth; the stack's compiler is a downstream consumer; the
registry consent governs plugin mounting only.

**Options.**
1. *Coexist (recommended).* Keep main's approval model as the single
   source of truth for native behavior; keep the stack's capability
   compiler as the wasm-boundary projection, ADAPTED to main's new
   store shapes (see the store-shape break). No user-visible behavior
   changes on either side; the wasm route gains main's new grant kinds
   for free once the launcher maps them.
2. *Theirs-supersedes everywhere.* Drop the capability document from
   the native boot path (keep it wasm-only). Loses native parity
   guarantees (`parity_native_test`, `capability_seeded_tools_test`)
   and the single-compiler property; the stack's tests pin parity —
   they would need deleting, which this merge forbids without review.
3. *Ours-supersedes.* Replace main's stores with the compiled document
   as native source of truth. Rejects two releases of shipped native
   UX (prefix menus, exact approvals, settings surfaces) — clearly
   wrong.

**Recommendation: option 1.** Concretely in this merge: main's versions
of `tina_approvals`, `tina_approvals_tui`, `tina_mode`, `tina_tools`
approval machinery land as-is; the stack's `tools_plugin.dart`
capability seeding coexists (capability-seeded directories never write
to the command stores — the layers do not touch); the stack's launcher
mapping is adapted to the new entry kinds. Flagged
**decided-by-me-pending-Nick-review** in the merge report.

## Store-shape break (the one hard incompatibility — must fix in the merge)

The stack's `engine_launcher.readCapabilityInputs` reads remembered
command grants as `entry['pattern']` (v0.9.111 shape). Main's
`3e7f649b`/`c2eb97d4` rewrote `commands.json` entries into kinds:
`command_prefix` (`prefix: List<String>` + `command`) and
`command_exact` (`arguments` + `command`). Unadapted, every remembered
grant silently compiles to nothing — the wasm document would lose
command grants while native keeps honoring them. **Fix**: map both new
kinds to `CommandRuleInput`s (prefix entries → scoped patterns; exact
entries → exact-match rules), keeping `grant:<id>` origins.

## The 12 overlapping files (resolution class each)

| file | stack change | main change | resolution |
|---|---|---|---|
| `apps/tina_cli/lib/src/assembly.dart` | capability compile wiring, skipped-plugins notice, provider `alwaysSelected` | 2 help lines | union |
| `apps/tina_cli/lib/src/pipes.dart` | +371 wasm pipes surface | 4 lines (formatting) | union |
| `apps/tina_cli/lib/src/plugin_catalog.dart` | +5 `skippedPluginIds` | +63/-51 execution settings + approvals channel | union + adapt (stack's ids preserved alongside main's rework) |
| `apps/tina_cli/lib/src/plugin_settings.dart` | +29 skipped-plugins | 1 line | union |
| `apps/tina_cli/pubspec.yaml` | +5 deps | version bump | union |
| `apps/tina_cli/test/app_test.dart` | +13 | +3/-2 | union |
| `packages/libraries/tina_wasm/lib/src/portable_tools_plugin.dart` | 1 line | +46/-29 (review wording) | **theirs** (main's review model; stack's line is a no-op against it) |
| `packages/plugins/tina_chat_tui/test/console_test.dart` | +13 | +84/-8 | union |
| `packages/plugins/tina_tools/lib/src/tools_plugin.dart` | +34/-9 capability seeding | +165/-145 execution settings/prefix/exact | union + seam care (capability seeding vs main's constructor params) |
| `packages/tina_console/lib/src/input_log.dart` | +4/-5 | +2 | union |
| `packages/tina_console/lib/src/line_editor.dart` | +3/-4 | +12/-4 (history reset) | union |
| `packages/tina_console/lib/tina_console.dart` | +2/-2 exports | +1 export | union |

Plus the non-conflicting but load-bearing adaptation:
`apps/tina_cli/lib/src/engine_launcher.dart` (store-shape break above).

## Mouse drag selection vs the stack's TUI input (question b)

Orthogonal. Main's drag-copy lives in `mouse_selection.dart` +
`input_parser`/`input_event`/backends — files the stack never changed —
and routes through `console_contribution`/`screen` hooks that exist on
both sides. The stack's `tina_console` work (regions, panels, image
console) does not model pointer input. The three shared files conflict
textually only. Keep main's feature whole.

## What main fixed that the stack never had (question c)

Paged resume, drag-to-copy, input-history reset, model-preservation in
the providers panel, status-bar scroll hints, auto-summary noise
removal, smoke-expectation repairs — all land as genuinely new. Nothing
in the stack's diff reverts or depends on their absence.

## Cannot be validated in this environment

- The **engine artifact** (`engine.wasm` @ 18d210d1, built from
  `f2319a7c`): main's `session_observation.dart`/tools changes enter the
  engine's Dart sources after the merge, so the artifact no longer
  matches merged sources. It still boots (validated), but a rebuild is
  owed before the next engine-side release. Noted, not silently done:
  rebuilding requires the pinned wasm.dart toolchain outside this tree.
- `tool/smoke_*.py` terminal probes (need real terminals/notcurses
  runtime) — kept as main's, not run.
- The `dart_notcurses` submodule pointer: keeping main's; the stack's
  wasm TUI spikes compile against the same pointer (submodule content
  fetched for tests where needed).

## Findings during resolution (audit addendum)

Three things the file-level audit under-weighted, resolved and recorded:

1. **Box-model permissions (4f0bc8b1, under v0.9.116/117) changed the
   mode ROUTE table**, not just the approval stores:
   `PermissionMode.normalized` collapses ask/allowEdits/readOnly →
   `approve`, and un-granted workspace writes route **human** in every
   non-yolo mode (probe: ask/readOnly/allowEdits/auto all human, yolo
   allow). The stack's vendored parity table encoded allow (allow-edits)
   and deny (read-only). Resolved theirs-supersedes: both tina copies of
   `parity-scenarios.json` updated (kept byte-identical); **wasm.dart's
   vendored copy + host-side wall semantics now diverge until synced** —
   the #1 cross-repo follow-up, needs Nick's call on whether the wasm
   structural wall mirrors main's human-routing or keeps the stronger
   wall with per-side rows.
2. **The stack widened `Stdio`** (terminal modes, line count) and
   main's two NEW test fakes (`resume_paging_test`, approvals_tui
   `console_test`) implement the old interface — completed with inert
   members, not deleted.
3. **The stack's pipes mode-receipt test** asserted the stale-mode
   invariant through legacy mode names that now normalize to the same
   value — rewritten to exercise the same invariant with the two live
   modes (auto/approve). The invariant (stale expectation → failed
   receipt) is unchanged.

Also confirmed during validation: main's grant machinery FIXES 22
sandbox-environment failures the stack's own tina_tools suite carried
(stack baseline 22 → merged 0).

## Step-2 directives

1. Union the 12 overlap files per the table.
2. Adapt `engine_launcher.dart` to the `command_prefix`/`command_exact`
   store shapes (grant origins preserved).
3. Keep every main file not listed above as-is; keep every stack-only
   library as-is.
4. Baselines before merging: full suites at `18d210d1` and `5c4ec7d4`
   recorded; the merged tree must not regress either.

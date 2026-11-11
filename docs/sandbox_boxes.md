# Sandbox boxes — replacing prediction with containment (Stage A)

Status: Stage A, landed behind an opt-in. The classifier/modes stack is
untouched and stays the default; this note describes the parallel path,
its rules, and the follow-ups.

## The idea

The current approval stack predicts what a command will do (classifier,
effect assessments, precedents, pattern grants, three grant scopes, five
modes). Prediction is prompt-heavy and wrong in both directions: inline
`python3 -c` scripts prompt constantly on hosts without a confinement
backend, while anything the predictor misreads slips through.

The box model stops predicting and starts containing. Every command sorts
into one of three boxes before it runs:

1. **Box 1 — read-only in the workspace.** Run inside the enforced
   read-only profile (workspace bound read-only, private temp scratch
   writable, no network). Never asks.
2. **Box 2 — writes/network inside an allowed scope.** Run inside an OS
   sandbox profile fitted to the command family. Silent; one report line
   per command at end of turn.
3. **Box 3 — needs something no box provides.** Admin, raw network
   outside a profile, paths outside the mounts. Asks through the existing
   approval dialog; a remembered pattern lands in the box allowlist.

What makes this safe without prediction is the jail: a box-2 command can
only touch what its profile mounts. The sorter does not need to know what
a script *does* — only which family it belongs to and that everything it
names sits where a profile can hold it.

## The sorter (`box_sorter.dart`)

Pure: a request plus an injected context in, a box plus a suggested
profile out. It reuses the quote-aware literal shell parsing the
certified-reader path already owns (`read_only_commands.dart` — words,
operators, redirects), extended with one heredoc shape that grammar
cannot express (it rejects newlines): `<interpreter> [flags] <<MARKER`
with a body ending at the marker line. The heredoc body is data to a
contained interpreter, so only the first line is parsed.

Rules, in order:

1. No confinement backend → box 3 (the gate declines; the existing
   pipeline owns the command). Outside-sandbox requests → box 3.
2. Unparseable constructs (command substitution, backticks, `||`,
   subshells, globs, unterminated heredocs, …) → box 3. The sorter never
   guesses in favor of silence.
3. **Destructive components → box 3, always** — the destructive table is
   the same one `capability_envelope.dart` uses, applied per pipeline
   component. The allowlist cannot override this.
4. The allowlist decides next: a stored rule names the box/profile
   matches run in (including "keep asking").
5. Everything the command names must sit in the visible world: cwd,
   path-shaped operands, verified reads of certified readers, declared
   read directories. Outside → box 3.
6. Writes: file-redirect targets and declared write directories must sit
   in the workspace or the plan's writable world; otherwise box 3.
7. Family classification per component (build/packages tables below).
   Pipelines take the profile that covers every component.
   - interpreter (`python3 python node nodejs perl`) → **scripts**
   - package fetch (`dart|flutter pub get…`, `cargo fetch|update`,
     `go mod download|tidy|vendor`, `npm|yarn|pnpm|bun install…`,
     `pip install|download`, `python -m pip …`) → **packages** when
     network was declared, **build** otherwise (offline from caches)
   - build/test tools (`dart flutter cargo go make cmake ninja gradle
     mvn npm tsc jest pytest …`) and write-capable general commands
     (`git add|commit|checkout…`, `cp mv touch mkdir tee sed -i …`)
     → **build**
   - a network declaration on any other family, or any raw-network
     program (`curl wget ssh git push|fetch|clone …`), or a URL operand
     → box 3
   - everything else → **box 1** (read-only containment; an explicit
     `access: "read-only"` request forces box 1 for any program)
8. Redirects or declared writes upgrade scripts/read components to
   build; the read-only mode ceiling and yolo are handled by the gate,
   not the sorter.

Unknown programs are box 1, not box 3 — that is the point of containment:
an unrecognized binary under enforced read-only, offline, clean-env
confinement can read the workspace (which the model can read anyway) and
do nothing else. If it needs more, it fails loudly and the model retries
with declarations, which ask.

## Profiles (`box_model.dart`)

A profile is data — a `BoxProfileSpec` — never scattered flags:

| profile    | workspace | temp scratch | shared caches | network |
|------------|-----------|--------------|---------------|---------|
| `scripts`  | read-only | writable     | —             | off     |
| `build`    | read-write| writable     | writable      | off     |
| `packages` | read-write| writable     | writable      | **on**  |
| `default`  | read-only | writable     | —             | off     |

`boxProfileBwrapArguments` maps a spec onto the bwrap argv
(`buildBwrapArguments`) the OS sandbox runner builds — and a test asserts
that mapping is byte-identical to what `OsSandboxRunner` assembles for
the profile's control flags (`readOnly`, `networkAllowed`), so the
profile can never drift from the enforcement. Shared caches ride the
existing sandbox-home targets (`tina/tools/home_caches`), so the
`packages` profile is "network + workspace + the caches the owner
already shared", not a new mount concept.

## The gate (`box_gate.dart`) and the silent path

`BoxModelGate` sits inside `SandboxedProcessRunner.run`, before the
existing decision pipeline. When the opt-in is off (or the gate declines)
nothing changes. When on:

- Box 1 runs with `readOnly: true`, no network — certified readers still
  get their pinned spawn.
- Box 2 runs with its profile's control flags, no approval round trip,
  and accumulates one report line per command:
  `dart test packages/tina_core — box 2, profile build (…)`, emitted at
  end of turn like the auto-mode batch.
- Box 3 falls through to the existing pipeline, which asks exactly when
  it asks today (a declared network or write ask, an outside-sandbox
  ask). The gate adds no ask of its own in Stage A.
- Read-only mode keeps box 1; writable/networked profiles fall through
  so the existing ceiling refuses them. yolo skips the gate entirely.

Without a confinement backend the gate declines everything: boxes are
containment, and there is no silent box without a jail.

## The allowlist (`box_allowlist.dart`)

The one list. Plain text, versioned, hand-editable:

```text
# tina box allowlist v1
# One rule per line: <glob> -> <box[/profile]>
# boxes: 1 read-only, 2 contained, 3 ask; profiles: scripts build packages default
version 1
dart test* -> 2/build
curl * -> 2/packages
vendor-tool* -> 1
```

- Two files: `<workspace>/.tina/box_allowlist` (project) and
  `~/.tina/box_allowlist` (global). Project rules are consulted first.
  No session/workspace/global triple.
- Globs match the command line the dialog shows; `*` spans anything,
  `?` one character. A rule names the box/profile matches run in, so a
  stored `curl *` authorizes network for matching commands — it is the
  owner's standing grant.
- The first non-comment line must be `version 1`; otherwise the file is
  ignored with a reported error. Damaged lines are skipped and reported,
  never fatal. Every lookup rereads disk, so edits apply immediately.
- Box-3 asks reuse the existing "always allow this pattern" choice. The
  dialog speaks regex; the list speaks glob, so the answer is translated
  (`prefix.*` → `prefix*`, escapes unescaped). Patterns a glob cannot say
  exactly (alternation, classes, anchors) keep the existing scopes-store
  semantics instead of masquerading as globs.
- A stored rule is derived from the approved run: read-only-approved →
  `1`, network-approved → `2/packages`, otherwise `2/build`. The
  remember-workspace answer writes the project file; remember-global
  writes the global file.

## The opt-in

A settings key: **`tina/tools/permission_boxes`** (toggle, default off,
session/workspace/global scopes). Rationale over the alternatives:

- A new `PermissionMode` value would ripple through `/mode` cycling, the
  prompt sections, and the decision-pipeline ceilings — the exact stack
  Stage A must not rewire — and a mode is a ceiling, not a routing.
- A CLI flag cannot be reviewed per project or persist across sessions.
- A setting is live (read per command), shows up in Settings →
  Permissions with its description, defaults to off, and needs zero
  plumbing: the tools plugin already holds `ScopedSettings`.

Native CLI only: the key is registered by the `tina/tools` plugin
definitions (tina_tools and the CLI catalog). The wasm composition root
injects its own tools plugin and never reads the key; the wasm path and
`asking_boundary.dart` are untouched.

## Follow-ups

- **Classifier deletion plan (Stage B).** Once boxes run for the owner:
  make the sorter the only decision path; delete the classifier, effect
  assessments, precedents, and the five-mode table; reduce modes to the
  box ceilings (read-only ≈ box 1 only). The `scripts`/`build` families
  replace the workflow grants; the allowlist replaces the scopes store
  (a migration can translate exact-command grants 1:1 into rules).
- **Wasm path unification.** `asking_boundary.dart` keeps the prediction
  model because WASI has no jail. When wasm grows a confinement story
  (preopen-scoped profiles map cleanly onto `BoxProfileSpec`), the
  sorter is pure and portable — adopt it there and delete the parallel
  logic.
- Box-2 `CommandBlocked` outcomes could offer the existing single-retry
  directory-grant flow instead of failing to the model.
- The `packages` family table wants an escape hatch for private
  registries (a pattern like `pip install --index-url …` is build-profile
  today and asks when network is declared).

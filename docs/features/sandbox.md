# Tool Sandbox — OS-level confinement around bash

## Status (updated 2026-09-09)

Shipped: macOS `sandbox-exec` write-confinement (the tool-use approval audit's
Fix 2), Linux `bwrap` write-confinement parity plus the opt-in
`--sandbox-net` / `--sandbox-readonly` tightening (tin-k9q3), and runtime
approval for additional writable directories. Deferred:
`--sandbox-cpu` (no portable CPU-quota story — cgroups on Linux, macOS-only
resource limits under sandbox-exec).

Code: `packages/tina_engine/lib/src/tools/sandbox_runner.dart` (the backend
dispatch, both profile builders, the pass-through degradation), wired through
`ProjectToolScope` (`packages/tina_engine/lib/src/agent/project_tool_scope.dart`).
Directory grants live in `packages/tina_engine/lib/src/permissions/sandbox_access.dart`.

## Why a structural guard

The bash denylist (a regex on raw shell) is a speed bump, not a sandbox: a
destructive command can be routed around it with `python3 -c` or
`base64 -d | sh`. The sandbox is the structural backstop — the command runs
under an OS confinement that simply has no write permission outside the
project, whatever the shell text looked like.

## Backends

| platform | backend | default posture |
| --- | --- | --- |
| macOS | `sandbox-exec -p <profile>` (Seatbelt) | writes confined to project root + temp; **reads, network, process stay open** |
| Linux | `bwrap <binds> --` (user namespaces) | system dirs bound read-only, project root + temp writable, `--dev`/`--proc` provided; **home, mounted volumes, and system directories are visible read-only; unmounted paths are invisible**; network on |
| other | pass-through | no OS-level confinement; the denylist + permission gate still apply |

The asymmetry in the default posture is deliberate. On macOS the Seatbelt
profile keeps `(allow default)` as its baseline and only carves out write
denials — reads stay open, matching the tool sandbox's historical scope. On
Linux the namespace is cheap and strictly stronger, so the default takes it:
whatever bwrap does not mount does not exist for the subprocess. Concretely:
`git`/`grep`/compilers work (system dirs are bound read-only, the project is
writable). Commands can read home directories and mounted toolchains, but
writing outside the project/temp roots needs an explicit writable grant.

Escape hatches (all compose):

- `--no-sandbox` — disable confinement entirely (e.g. a command that must
  write to `$HOME` or system paths).
- `TINA_SANDBOX_ALLOW=/path:/other` — extra writable roots (colon-separated,
  existing directories, same on both backends; granted even under
  `--sandbox-readonly`).
- `--sandbox-net` — unshare the network namespace (Linux `--unshare-net`,
  macOS `(deny network*)` + a remote-write deny). Off by default: builds,
  package installs, and `git fetch` need egress.
- `--sandbox-readonly` — drop the writable project grant (the project stays
  readable; temp remains writable) for pure read/analyze runs. On macOS it
  additionally denies reads under `/Users` and re-grants the project
  read-only.

## Runtime directory approval

The main agent can request extra writable directories on a `bash` call:

```json
{
  "command": "dart test",
  "writablePaths": ["/mnt/hdd_2tb/flutter/bin/cache"],
  "accessReason": "The Flutter Dart launcher updates engine stamp and realm metadata."
}
```

The approval shows the command, canonical directory paths, and reason:

- **y** approves the command and directories for this invocation only.
- **a** approves the command once and grants those directories for the current
  project session, shared by its main agent, delegates, and other agents
  borrowing the same project tool scope.
- **n**, **Esc**, or **Ctrl+C** denies the invocation.

A directory grant includes its contents. Paths must be absolute, existing
directories; symlinks are resolved before approval. Request a narrow cache
directory, not a whole SDK or home directory. An approved canonical path that
changes into a symlink is rejected before it can widen access.

Ordinary command allow rules, `--yolo`, and the automatic permission classifier
never approve new writable roots. Existing command deny rules still apply.
Session directory grants do not install command allow rules and are not saved
across restarts. `TINA_SANDBOX_ALLOW` remains the startup mechanism, including
for headless runs, which refuse interactive directory requests. Explicit
runtime grants can override `--sandbox-readonly`, just like startup grants.
When the sandbox is disabled or unavailable, no directory escalation is needed.

Each approved invocation gets a runner with its own access snapshot. An
allow-once answer never changes the runner used by concurrent agents. This
only grants subprocess access; the in-process file tools retain their project
boundaries.

On the first identifiable `Read-only file system` failure, Tina reports the
blocked file paths and explains that command approval did not grant writes
there. It identifies only existing immediate parent directories (or the named
directory itself), without guessing broader roots. Ordinary `Permission denied`
and errors without a clear path retain investigation guidance.

Before retrying, the agent must inspect possible partial effects and submit the
same command/cwd with `retrySafety` describing those checks. A retry precomputed
in the failed tool batch is rejected. Tina then shows the original failure,
the agent’s assessment, and the precise directories in a fresh **once / session /
deny** approval. Approval executes that submitted retry; failures are never
replayed blindly. Denying the retry suppresses repeat requests for that command
and cwd during the turn. A failed approved retry also stops the approval loop.

## Known limitations

- **`--sandbox-net` gates bash subprocesses only.** The engine-level
  `fetch` and `web_search` tools make their own HTTP requests in-process and
  are NOT covered; network isolation is therefore not a hard egress boundary
  while those tools are enabled. Gating them is a separate ticket (see
  tin-k9q3's open questions).
- bwrap needs unprivileged user namespaces; on hosts where the administrator
  disabled them (`kernel.unprivileged_userns_clone=0` or
  `user.max_user_namespaces=0`) or the binary is absent, the Linux sandbox
  degrades to pass-through with a one-time warning naming the reason.
- No CPU/memory quota (`--sandbox-cpu` deferred — see Status).

## Where it hooks in

`ProjectToolScope` wraps its shared `BashTool` process runner in a
`SandboxedProcessRunner`. The runner owns a `SandboxAccessPolicy`, seeded from
startup grants. The agent permission gate validates requests, collects an
explicit answer for new directories, and creates an invocation runner after
approval. Session grants update the shared policy; once grants stay on the
invocation copy. Direct `BashTool.execute` calls reject unapproved requests.

Wrapping at the `ProcessRunner` seam preserves BashTool's streaming,
cancel/timeout/kill-tree logic. The resolved backend is reported once at
startup through the sandbox logger.

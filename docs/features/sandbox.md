# Tool Sandbox — OS-level confinement around bash

## Status (updated 2026-08-29)

Shipped: macOS `sandbox-exec` write-confinement (the tool-use approval audit's
Fix 2), Linux `bwrap` write-confinement parity plus the opt-in
`--sandbox-net` / `--sandbox-readonly` tightening (tin-k9q3). Deferred:
`--sandbox-cpu` (no portable CPU-quota story — cgroups on Linux, macOS-only
resource limits under sandbox-exec).

Code: `packages/tina_engine/lib/src/tools/sandbox_runner.dart` (the backend
dispatch, both profile builders, the pass-through degradation), wired through
`configureToolSandbox` (`packages/tina_engine/lib/src/agent/agent_pipeline.dart`)
from `lib/config.dart`.

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
| Linux | `bwrap <binds> --` (user namespaces) | system dirs bound read-only, project root + temp writable, `--dev`/`--proc` provided; **`$HOME` and the rest of the filesystem are not mounted — unmounted means invisible**; network on |
| other | pass-through | no OS-level confinement; the denylist + permission gate still apply |

The asymmetry in the default posture is deliberate. On macOS the Seatbelt
profile keeps `(allow default)` as its baseline and only carves out write
denials — reads stay open, matching the tool sandbox's historical scope. On
Linux the namespace is cheap and strictly stronger, so the default takes it:
whatever bwrap does not mount does not exist for the subprocess. Concretely:
`git`/`grep`/compilers work (system dirs are bound read-only, the project is
writable), but a command that wants `$HOME` (dotfiles, caches, `~/.ssh`) needs
`--no-sandbox` or a `TINA_SANDBOX_ALLOW` grant.

Escape hatches (all compose):

- `--no-sandbox` — disable confinement entirely (e.g. a command that must
  write to `$HOME` or system paths).
- `TINA_SANDBOX_ALLOW=/path:/other` — extra writable roots (colon-separated,
  same on both backends; granted even under `--sandbox-readonly`).
- `--sandbox-net` — unshare the network namespace (Linux `--unshare-net`,
  macOS `(deny network*)` + a remote-write deny). Off by default: builds,
  package installs, and `git fetch` need egress.
- `--sandbox-readonly` — drop the writable project grant (the project stays
  readable; temp remains writable) for pure read/analyze runs. On macOS it
  additionally denies reads under `/Users` and re-grants the project
  read-only.

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
- `$HOME` is not mounted on Linux even for reads; macOS reads stay open
  (including `$HOME`).
- No CPU/memory quota (`--sandbox-cpu` deferred — see Status).

## Where it hooks in

`configureToolSandbox` wraps the shared `BashTool`'s `ProcessRunner` in a
`SandboxedProcessRunner` once per session (idempotent; re-run on setup
relaunch and by the environment/summary runners for their explicit project
root). Wrapping at the `ProcessRunner` seam leaves BashTool's
cancel/timeout/kill-tree logic untouched, and tests that inject a fake runner
directly into `BashTool` bypass the sandbox. The resolved backend is reported
once at startup through the `tina.sandbox` logger
(`bash sandbox: <backend description or pass-through reason>`).

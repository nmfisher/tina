---
id: tin-k9q3
status: done
deps: []
links: []
created: 2026-08-13T12:00:00Z
type: feature
priority: 3
assignee: Nick Fisher
tags: [sandbox, bash, linux, security, hardening, subprocess]
---
# Extend the bash sandbox to Linux + tighter containment modes

The bash subprocess is OS-sandboxed **only on macOS** (`sandbox-exec` via
`SandboxedProcessRunner`); on Linux the runner is a no-op pass-through, so the
denylist + permission gate are the *only* guards between a runaway agent and the
filesystem. Separately, the macOS sandbox is **write-only by design** — reads and
network stay open, leaving a confidentiality/exfiltration residual. This ticket
closes both gaps.

## Current state (what exists today)

The bash call layering today:

```
policy gate → cwd confinement → denylist (regex) → OS sandbox → kernel
```

- `packages/tina_engine/lib/src/tools/sandbox_runner.dart` — `SandboxedProcessRunner`
  rewrites argv to `sandbox-exec -p <profile> …`. macOS-only; gated by
  `sandboxExecAvailable`.
- `BashTool.processRunner` is the swap seam (mutable, set in
  `agent_pipeline.dart:configureToolSandbox`).
- Profile is write-confinement: `(allow default)` then `(deny file-write*)` then
  re-grant project root + temp + `/dev/null` + `/dev/dtracehelper` + `TINA_SANDBOX_ALLOW`
  extras.
- Escape hatches already shipped: `--no-sandbox` (disable), `TINA_SANDBOX_ALLOW`
  (colon-separated extra write roots).

So: macOS has a structural guard; **Linux has none**; and even macOS leaves reads +
network open (`cat /etc/passwd`, `~/.ssh` reads, network exfil all pass).

## Goal

1. **Linux write-confinement parity** — a kernel-level guard so a destructive command
   (or a denylist evasion like `python3 -c "os.remove(...)"`) cannot write outside the
   project on Linux either.
2. **Opt-in deeper containment** (both platforms) — network isolation and read-hiding
   for users who want stronger isolation and will configure extra allow-paths.
3. **No default breakage** — behaviour unchanged unless the user opts into a stricter
   mode or is on a platform with the sandbox binary present.

## Design

**Platform-dispatch inside `SandboxedProcessRunner`** (the same argv-rewrite seam,
unconditional inside `BashTool.execute`, graceful pass-through when unavailable):

```
SandboxedProcessRunner
 ├─ macOS  → sandbox-exec -p <profile> …          (shipped)
 ├─ Linux  → bwrap <binds> -- /bin/sh -c …        (new)
 └─ other  → pass-through + one-time warning        (shipped)
```

**Bubblewrap profile (Linux).** `bwrap` is namespace-first — everything not mounted is
invisible, not just unwritable. For write-confinement parity, bind project writable,
system dirs read-only, temp writable:

```sh
bwrap \
  --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
  --ro-bind /bin /bin --ro-bind /sbin /sbin \
  --bind <projectRoot> <projectRoot> \
  --bind /tmp /tmp --bind <TMPDIR> <TMPDIR> \
  --dev /dev --proc /proc \
  -- /bin/sh -c "<command>"
```

Reuse `TINA_SANDBOX_ALLOW` for extra writable roots (same extension point as macOS).
`bwrap` needs no root (user namespaces), but hardened kernels disable unprivileged
userns → detect and pass-through with a warning, same as "binary missing."

**Opt-in tighter modes (both platforms, off by default):**

| Flag | macOS (`sandbox-exec`) | Linux (`bwrap`) |
|------|------------------------|-----------------|
| `--sandbox-net` | `(deny network*)` + `(deny file-write* (remote))` | `--unshare-net` |
| `--sandbox-readonly` | `(deny file-read* (subpath "/Users"))` + project allow | drop `--ro-bind /Users`; bind only project + system |
| `--sandbox-cpu <s>` | `(resource-limit (cpu <s>))` | cgroup-based (heavier; defer) |

Compose with existing `--no-sandbox` and `TINA_SANDBOX_ALLOW`.

## Design questions to resolve

- Linux default posture: write-confinement parity (everything readable, project+temp
  writable, net on — matches macOS, least break-prone) vs full isolation. Recommend
  parity as default, `--sandbox-readonly`/`--sandbox-net` for the stronger posture.
- Landlock (kernel ≥ 5.13, no helper binary, pure-kernel) instead of/alongside `bwrap`?
  Needs FFI to the `landlock_*` syscalls — defer unless zero-binary-dependency
  containment is wanted; `bwrap` is far less code.
- Should `--sandbox-net` also gate the `fetch`/`web_search` tools? Network isolation is
  only meaningful if it covers all egress paths, not just bash.
- Single `--sandbox=<off|write|strict>` selector vs the granular flags above?

## Out of scope

- A full container/VM per command (too heavy for the dev-tool inner loop).
- Sandboxing reads/network **by default** (breaks `git fetch`, package installs, toolchain
  resolution).
- Windows support (no native equivalent worth shipping).

## Acceptance criteria

- [ ] `SandboxedProcessRunner` dispatches by platform: `sandbox-exec` on macOS, `bwrap` on
      Linux, pass-through elsewhere; detection + graceful degradation when the binary is
      absent or user namespaces are disabled.
- [ ] Linux `bwrap` profile binds project root + temp writable, system dirs read-only, and
      `TINA_SANDBOX_ALLOW` extras.
- [ ] Opt-in `--sandbox-net`, `--sandbox-readonly` (and optionally `--sandbox-cpu`) wired
      through `lib/config.dart` and `configureToolSandbox`.
- [ ] Tests mirroring `packages/tina_engine/test/tools/sandbox_runner_test.dart`: profile construction, argv
      rewrite (fake inner runner), pass-through when disabled, and a Linux-guarded
      integration test (write under project succeeds; write outside blocked; `--sandbox-net`
      blocks a localhost `curl`). Platform groups skipped appropriately.
- [ ] `cd packages/tina_engine && dart test` green; `dart analyze` clean.
- [ ] Startup log line reports the active sandbox backend per platform.

## Status

**Done (2026-08-29, round 10).** Platform dispatch landed inside
`SandboxedProcessRunner` (`packages/tina_engine/lib/src/tools/sandbox_runner.dart`):
`resolveSandboxBackendFor` (pure, unit-tested) → macOS `sandbox-exec`, Linux
`bwrap` (requires binary **and** unprivileged user namespaces via `/proc` knob
probe), everything else / `--no-sandbox` → pass-through with a one-time
warning (injectable sink). Linux profile via `buildBwrapArgs()` — pure argv
builder from `(projectRoot, tempDirs, allowExtras, readOnlyBinds, flags)`:
system dirs ro-bound only when present, project + temp rw, `--dev/--proc`,
`TINA_SANDBOX_ALLOW` extras, `--sandbox-net` → `--unshare-net`,
`--sandbox-readonly` → project `--ro-bind`. Deliberate Linux default-posture
asymmetry (namespace-first: `$HOME` unmounted = invisible, stronger than the
macOS open-read baseline) documented in the new `docs/features/sandbox.md`,
alongside the known residual (`--sandbox-net` gates bash only; `fetch` /
`web_search` egress ungated). `--sandbox-cpu` deferred (no portable story —
cgroups vs macOS-only resource limits). Flags wired through
`lib/config.dart` (`--sandbox-net` / `--sandbox-readonly`, matching the
`--no-sandbox` pattern) and every `configureToolSandbox` call site; startup
diagnostic `bash sandbox: <backend>` on the `tina.sandbox` logger. Tests:
`packages/tina_engine/test/tools/sandbox_runner_linux_test.dart` (dispatch
matrix, degradation reasons, argv builder incl. mount-shadowing order,
pinned-backend rewrite + warn-once, and 4 bwrap-gated integration tests that
register only where bwrap exists); macOS tests unchanged in behavior with the
backend pinned; +1 flag-composition test in `test/permissions/config_test.dart`.
Engine suite 830 green, root 824 green, `dart analyze` clean in both.

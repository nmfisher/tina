# Engine2 process sandbox

`tina/tools` owns process confinement and permission enforcement. Both `exec`
and `bash` use the same runner; switching shells does not change confinement.
The engine loop and approval renderer do not implement sandbox policy.

| Backend | Filesystem | Network |
| --- | --- | --- |
| macOS `sandbox-exec` | Host reads; writes restricted to workspace, temp and configured writable paths | Isolated unless explicitly approved |
| Linux `bwrap` | Existing `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/etc`, `/opt` mounted read-only; workspace, temp and configured writable paths mounted writable; fresh `/dev` and `/proc`; Tina metadata mounted read-only | Isolated unless explicitly approved |
| Unavailable backend | Default fallback runs approved commands without OS confinement and warns; embedding can instead refuse | No OS isolation when running without a jail |

Linux paths outside these mounts are hidden, including home toolchains and other
volumes unless a listed mount covers them. The model receives the actual mount
list in the tools prompt. Built-in file tools inspect the host under their own
permission policy, so successful `stat` or `read` does not prove a subprocess
can reach the same path. macOS does not hide home paths in this way.

## Disable for a launch

```sh
tina --no-sandbox
tina --continue --no-sandbox
dart run bin/tina.dart --no-sandbox
```

This removes OS filesystem and network confinement for new commands in that
launch, including panels and subagents. It preserves mode/approval checks and
the filtered subprocess environment. It does not grant root privileges. Without
an OS jail, `network: false` cannot block network access. Built-in file tools
retain their permission policy.

The flag is not stored in config or session data. `/update` restart passes it
to the replacement process; a normal later launch must specify it again.
Headless runs accept the flag but still deny requests needing a human.

## Request an exception for one command

```json
{
  "program": "/home/user/blender/blender",
  "args": ["-b", "--factory-startup"],
  "outside_sandbox": true,
  "sandbox_reason": "This installed program exists on the host but is hidden from the Linux subprocess mounts."
}
```

`bash` accepts the same fields alongside `command`. The tools plugin requests
separate human approval, even in auto mode. It explicitly grants host filesystem
**and network** access to the command and its children: removing the jail also
removes OS network isolation. The environment remains filtered. Ordinary
execution approvals and network approvals cannot authorize this exception.

Allow once covers one invocation. Always covers the exact executable, arguments,
directory, environment and stdin for the current session, with no wildcard
widening. A later identical call must still set `outside_sandbox: true` to use
that grant. Normal calls remain confined. Denial/cancellation starts no process
and creates no grant. Grants expire on exit; panels and subagents keep their own
command grants.

A hidden host executable produces a specific diagnostic and instructions for
this API. Errors from genuinely missing files and missing loaders for visible
programs remain ordinary failures. Nothing automatically repeats a failed
command; a retry executes the entire command again.

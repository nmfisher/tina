# Engine2 authorization and process sandbox

The user-facing rules and saved-grant format are documented in
[resource permissions](permissions.md). `tina_mode.resolveAuthorization` is the
shared policy table. File/process boundaries supply canonical access facts,
check human grants, route uncovered access, and revalidate paths after approval.
Modes choose the reviewer: `approve` uses the human; `auto` uses the model for
external access. The first workspace write always requires a human session grant.

## Process access

Both `exec` and `bash` accept `access: "read-only"` or
`access: "workspace-write"`. Until the workspace has a write grant, commands
receive a read-only workspace. Request workspace-write explicitly for mutations;
known file operands can also expose required access before launch. After the
human grants writes, ordinary commands can write across the workspace.
Explicit read-only access still clamps the entire invocation, including external
paths. A read-only invocation fails closed without an OS sandbox.

External execution requires approval per invocation, including ordinary system
executables. Recognized commands contribute access facts; recognition never
waives review. Scripts and interpreters use the same rules. Runtime read paths
are included in command review and can be saved as read grants. Workspace and
external writability are independent: an external writable grant does not grant
workspace writes.

| Backend | Filesystem | Network |
| --- | --- | --- |
| macOS `sandbox-exec` | Positive read rules and approved writable paths; workspace write grant checked separately; control data protected | Isolated unless approved |
| Linux `bwrap` | Narrow runtime mounts, workspace, private scratch and approved paths; writable mounts checked separately; control data masked | Isolated unless approved |
| Unavailable / disabled | Host execution requires human authorization; explicit read-only execution refused | No OS isolation |

The runtime allowances cover installed system binaries, libraries, public
TLS/resolver configuration and platform runtime files. They do not expose the
entire host filesystem. File tools enforce access separately from subprocesses.

## Home and protected data

Commands receive a private session HOME and TMPDIR under `~/.tina/sandbox-homes`.
Host caches and temporary directories are not shared automatically. Grant desired
external cache paths through the regular approval dialog. The legacy home-caches
setting no longer shares host directories. Session scratch is cleaned up when
owned jobs finish.

Workspace Tina data, global Tina configuration and explicit config paths remain
protected from agent access. Broad workspace or directory grants cannot remove
those protections. Other suspected secret access must receive explicit human
review; the auto reviewer must deny it. An explicit unconfined invocation gives
broader host access as described in its human prompt.

## Extra paths, network and host execution

Both process tools accept `read_directories`, `write_directories`,
`working_directory`, `network`/`network_reason` and
`outside_sandbox`/`sandbox_reason`. Existing specific directories may be requested;
root-wide, home-wide and protected paths cannot be saved. Relative paths resolve
against the invocation cwd. A one-time approval affects only that subprocess tree.
Remember saves only selected file/directory access, per workspace.

`network: true` requires a nonempty reason and authorizes network access for that
invocation while retaining filesystem confinement. Saved file grants never imply
network access. No destination filtering is implied.

`outside_sandbox: true` requires a nonempty reason and a human decision on every
invocation. It authorizes host filesystem and network access for the subprocess
tree. The executable and filtered host environment are frozen before approval.
Provider tokens are not inherited. Declining starts nothing.

`tina --no-sandbox` disables confinement for the launch and its panels/children,
while retaining human host-authorization checks. It is not persisted. The explicit
launch-only `--yolo` compatibility override authorizes capabilities; confirmations
and configured confinement still apply.

## Cancellation and failures

Mode changes invalidate pending tickets and invocation approval caches, then
re-evaluate requests. Children follow the parent's mode and share its workspace
write grant. Stale responses cannot save grants or start work.

Undeclared access fails inside the sandbox. There is no automatic approval/retry
cycle: commands can have partial side effects, so a retry is a fresh invocation.
Command patterns, command-family profiles, workflow grants and approval
precedents do not authorize commands. This is pre-execution review with OS
confinement, without a syscall broker for hidden script effects.

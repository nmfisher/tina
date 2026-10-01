# tina_tools

The model-facing file tools (ls, read, write, edit, glob, stat) over a
[`FileSystem`](lib/src/file_system.dart) seam, plus the process tools
(`bash`, `exec`) over a [`ProcessRunner`](lib/src/process_runner.dart)
seam — and the two sandbox wrappers that decide, per call, what may run.

Value types come from `tina_core`. Tools declare invocation requirements;
permission policy lives on the seam the tool was handed, and a refusal
reaches the model as that call's tool result. `ToolsPlugin` mounts the executors through
`AgentPlugin.mountOn`. The host uses that common interface and imports no
concrete tools. The single `tina/mode` plugin owns permission state,
commands and approval routing. Tools consult its policy at their boundaries.

## The two seams

| seam             | real implementation | sandbox wrapper            | refusal shape      |
|------------------|---------------------|----------------------------|--------------------|
| `FileSystem`     | `IoFileSystem`      | `SandboxedFileSystem`      | `SandboxViolation` |
| `ProcessRunner`  | `IoProcessRunner`   | `SandboxedProcessRunner`   | `CommandRefused`   |

Both wrappers consult the same `tina/mode` policy and fail closed when no
approval service is available. The mode plugin's console attachment supplies
Shift-Tab and the status label; no separate `tina/mode-tui` plugin is loaded.

| Mode | Reads | Project writes | Commands / outside writes |
| --- | --- | --- | --- |
| `ask` (default) | allow | ask | ask |
| `read-only` | allow | human approval | verified ls/grep run; others ask |
| `allow-edits` | allow | allow | ask |
| `auto` | allow | classifier review | classifier review |

In `auto`, an exact completed ALLOW approves the operation once. DENY,
timeout, missing classifier or invalid response falls back to the configured
human approval channel. Read-only uses human approval for writes and commands
that are not certified direct system readers. Cancellation does not fall back to asking.
Human “always” grants remain session-scoped; classifier approvals do not create
persistent or session grants. Protected Tina paths and OS sandbox restrictions
remain enforced in every mode. Ordinary approval does not disable the OS sandbox.

In read-only mode, direct system `ls` and `grep` invocations with supported
GNU/BSD options run without an execution approval. The runner verifies and pins
the absolute system executable; a replacement on PATH, custom environment,
unknown option or shell wrapper asks. Arguments remain unchanged. Network and
outside-sandbox access still need their own approval. Other modes retain their
existing command review policy. An explicit approval allows the requested
operation without changing the mode.
`WritableDirectories` and network heuristics explain why a command needs
approval; they do not authorize it without review. `OsSandboxRunner` supplies
OS confinement separately.

## `bash` vs `exec`: the shape is the safety property

- **`bash`** takes a **command string**. The shell interprets all of it —
  pipes, expansions, redirects — so it can do anything the process can do.
  That is the point of the tool, and no argument checking makes it safe;
  only the runner's per-call decision does.
- **`exec`** takes a **program and argument list**. Arguments are passed
  unchanged, including options and subcommands. It does not insert `--` or
  interpret shell quoting, expansions, pipes or redirects. Both permission
  checks and the OS sandbox apply to the actual invocation. Dedicated tools
  can use `FencedArguments` when their particular program supports `--`.

They are two tools on purpose, not one tool with a mode flag: the
signatures say what each can and cannot do.

## Network access

`exec` and `bash` accept `network: true` with a required `network_reason`.
The process boundary checks execution and network grants separately, then asks
the mode plugin to review the whole action once for any missing permissions.
In auto mode, the safety judge sees the full command, tool input, required and
missing permissions, and network reason. ALLOW applies once; DENY, uncertainty
or failure asks the human. Other modes ask the human directly.

The human gets Allow once, Deny, and Always allow this command with network
access for this session. Always remembers the missing permissions for the exact
program, argv, directory, environment and stdin. An execution-only grant does
not authorize network. Explicit command patterns also grant execution only.
Grants are in memory, isolated between panels, and expire on exit/resume.
Cancellation cannot create a late grant or start the command.

Network access applies to the entire subprocess tree, without destination/domain
restrictions. Configured filesystem confinement is unchanged. Even a stored network grant
does not open access unless that invocation requests it. Declining starts no
process. There is no automatic retry: retrying executes the entire command again.
Without the flag, the default network policy applies.

`tina/approvals` correlates the decision and `tina/approvals-tui` renders generic
plugin-supplied descriptions and permission scope text. Neither owns network
policy; the OS wrapper enforces the approved invocation. Human-only review is
independent of permission versus Yes/No confirmation presentation.

## Refusals are results, not exceptions

Both tools convert a refusal (`SandboxViolation` / `CommandRefused`) into
`ToolResult.error(reason)` — an ordinary error result the model reads for
that call. A **non-zero exit is not a refusal**: it is a completed run marked as a failed
tool result, and the model sees its exit code and output as for a failing
build.

## OS confinement and process lifecycle

`ToolsPlugin` wraps `IoProcessRunner` with `OsSandboxRunner` (bubblewrap on Linux,
`sandbox-exec` on macOS), then the outer permission gate. Sandbox availability
and fallback policy remain explicit. `tina --no-sandbox` (embedding option:
`osSandbox: false`) bypasses OS confinement for that launch, including new panels
and subagents. Permission modes and approval checks remain active. Child
environments stay filtered. Without a jail, commands have host filesystem and
network access even when `network` is false. The switch is not saved in config
or a resumed session; an update restart carries it forward.

Both process tools also accept `outside_sandbox: true` with a required
`sandbox_reason` for a single invocation. This requests separate **human**
approval, including in auto mode, for host filesystem and network access to
the whole subprocess tree. Execution/network approvals alone cannot grant it.
Always remembers the exact program, argv, cwd, environment and stdin for this
session. Later calls still have to explicitly request `outside_sandbox`; ordinary
calls retain their configured confinement. Declining or cancelling starts
nothing. There is no automatic retry.

The tools prompt describes the actual OS backend and mounts. On Linux, built-in
file tools can see host paths hidden from subprocesses. An existing absolute
executable outside the mounts produces a specific error before spawn; matching
ENOENT diagnostics are also identified when the named file exists on the host.
Recovery instructions describe the real outside-sandbox approval API rather
than asking the user to move binaries or run commands manually.

Executors receive cancellation and an output callback through the generic loop
execution context. `ProcessControl` forwards these through both runner wrappers;
none of the runners depend on a terminal. `Process.start` feeds stdin and drains
both output streams live. Results retain a bounded tail (1 Mi characters per
stream), elapsed time, and distinct cancellation/timeout flags. Nonzero exits
remain ordinary completed results; cancellation and timeout are tool errors.

On cancel or timeout, the runner snapshots the POSIX process tree, sends TERM,
then KILL to survivors after a grace period. Cleanup completes before returning.
This is best effort: `pgrep` must be available, and detached/reparented daemons
or children forked after the snapshot can escape discovery. Pipes retained by descendants are bounded to a
one-second drain after the direct process exits.

`ToolsPlugin` owns a `ProcessJobs` runner outside the permission and OS sandbox
wrappers. When new user input arrives, a running command returns a job ID and
partial output while its process continues. `process` supports `status`, `wait`
and `cancel`; `wait_ms` optionally bounds a wait, and new input interrupts waits.
Waiting never reruns the original command. Closing the plugin cancels owned
jobs; `ProcessJobs.close()` completes after their process cleanup. Job IDs are
unique across plugin lifetimes; live jobs do not survive exit/resume. Completed
detached results remain available during the owning session.

For long builds, servers or polling loops, use `background: true` on `exec` or
`bash` to return a job ID immediately after approval and process startup. This
does not grant any permissions or detach a pending approval. Set an appropriate
`timeout` in seconds; the default 600-second timeout still applies in the
background. For example, `exec` with `program: "gh"`, `args: ["run", "watch",
"12345", "--exit-status"]`, `network: true`, a `network_reason`,
`background: true` and `timeout: 7200` watches a build without holding the
conversation. Inspect it with `process` using its `job_id` and `action: "status"`.

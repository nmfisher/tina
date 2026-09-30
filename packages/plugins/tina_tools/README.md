# tina_tools

The model-facing file tools (ls, read, write, edit, glob, stat) over a
[`FileSystem`](lib/src/file_system.dart) seam, plus the process tools
(`bash`, `exec`) over a [`ProcessRunner`](lib/src/process_runner.dart)
seam — and the two sandbox wrappers that decide, per call, what may run.

Value types come from `tina_core`. No tool declares its own permissions:
the thing that refuses is the seam the tool was handed, and the refusal
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
| `read-only` | allow | deny | deny |
| `allow-edits` | allow | allow | ask |
| `auto` | allow | classifier review | classifier review |

In `auto`, an exact completed ALLOW approves the operation once. DENY,
timeout, missing classifier or invalid response falls back to the configured
human approval channel. Cancellation and read-only never fall back to asking.
Human “always” grants remain session-scoped; classifier approvals do not create
persistent or session grants. Protected Tina paths and OS sandbox restrictions
remain enforced in every mode. Approval does not disable the OS sandbox.

Read-only still blocks all commands, including commands that merely read.
The legacy read-all shell-classification exception is not enabled.
`WritableDirectories` and network heuristics explain why a command needs
approval; they do not authorize it without review. `OsSandboxRunner` supplies
OS confinement separately.

## `bash` vs `exec`: the shape is the safety property

- **`bash`** takes a **command string**. The shell interprets all of it —
  pipes, expansions, redirects — so it can do anything the process can do.
  That is the point of the tool, and no argument checking makes it safe;
  only the runner's per-call decision does.
- **`exec`** takes a **program and values**. The tool assembles argv itself
  through [`FencedArguments`](lib/src/fenced_arguments.dart): every
  model-supplied value is emitted **after the `--` fence**, where POSIX
  argument parsing requires the program to treat it as a positional. A
  model value therefore *cannot* arrive as an option — `--pre=rm -rf /`
  lands as inert data — and the guarantee is structural, because
  `FencedArguments.build()` is the only way argv leaves the tool.

They are two tools on purpose, not one tool with a mode flag: the
signatures say what each can and cannot do.

## Refusals are results, not exceptions

Both tools convert a refusal (`SandboxViolation` / `CommandRefused`) into
`ToolResult.error(reason)` — an ordinary error result the model reads for
that call. A **non-zero exit is not a refusal**: it is a completed run, and
the model sees the exit code and output exactly as it would from a failing
build.

## OS confinement and process lifecycle

`ToolsPlugin` wraps `IoProcessRunner` with `OsSandboxRunner` (bubblewrap on Linux,
`sandbox-exec` on macOS), then the outer permission gate. Sandbox availability
and fallback policy remain explicit. `osSandbox: false` deliberately omits the
OS wrapper, while retaining the permission gate.

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

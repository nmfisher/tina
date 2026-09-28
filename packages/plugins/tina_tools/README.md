# tina_tools

The model-facing file tools (ls, read, write, edit, glob, stat) over a
[`FileSystem`](lib/src/file_system.dart) seam, plus the process tools
(`bash`, `exec`) over a [`ProcessRunner`](lib/src/process_runner.dart)
seam — and the two sandbox wrappers that decide, per call, what may run.

Value types come from `tina_core`. No tool declares its own permissions:
the thing that refuses is the seam the tool was handed, and the refusal
reaches the model as that call's tool result. `ToolsPlugin` mounts the executors through
`AgentPlugin.mountOn`. The host uses that common interface and imports no
concrete tools. `ModeCommandPlugin` receives its `ModeControl` and optional
`Terminal` explicitly.

## The two seams

| seam             | real implementation | sandbox wrapper            | refusal shape      |
|------------------|---------------------|----------------------------|--------------------|
| `FileSystem`     | `IoFileSystem`      | `SandboxedFileSystem`      | `SandboxViolation` |
| `ProcessRunner`  | `IoProcessRunner`   | `SandboxedProcessRunner`   | `CommandRefused`   |

Both wrappers use the same session mode (`normal` / `readOnly`) and approval
service, and fail closed: **no approver wired means deny**. Command requests
carry the full command to the configured channel.
An "always" answer is remembered per session — a path glob for the
filesystem, literal argv and cwd identity for processes — so the same operation
never asks twice.

### Process enforcement: the command × mode table

| mode     | inside the writable directories, no network | outside them / needs network |
|----------|---------------------------------------------|------------------------------|
| readOnly | deny, never asked                           | deny, never asked            |
| normal   | allow                                       | ask (deny if refused / no approver)  |

One shape is exempted from the quiet path regardless of its arguments: a
request whose argv collapses a shell command into a single string
(`/bin/sh -c <string>` — the `bash`-tool shape). What the string runs
cannot be proven from argv, so it **always asks** in `normal` (and denies
in `readOnly`); only an explicit session grant covers it silently.
`argumentsCollapsed()` is that test; literal argv (`exec`) keeps the table
above.

There is **no classifier** and no "statically read-only command" route: a
command string is not statically decidable, so `readOnly` refuses every
command outright and nobody is asked. In `normal`, a command runs without
asking only when its argv *provably* reads, or creates/edits/moves/deletes,
nothing outside the session's writable directories (`WritableDirectories`)
and it does not appear to need network while `networkOff` — the heuristic
errs toward asking, never toward silently allowing. What "provably" means
is narrow: `WritableDirectories.covers` checks the working directory and
the arguments that are path-shaped — starting with `/`, `./` or `../`, or
exactly `.` or `..`. A bare relative token like `etc/passwd` and an
option-embedded path like `--out=../../x` are not path-shaped and
therefore not judged; and the check says nothing about what the program
does once it runs — this is a gate on arguments, not a boundary on
behaviour; `OsSandboxRunner` supplies OS confinement separately.
`bash` cannot prove anything (the shell reads the string whole),
so in practice every `bash` call in `normal` asks unless a session grant
already covers it; `exec`'s argv *can* be judged, which is one more reason
the two tools exist as separate shapes.

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
or children forked after the snapshot can escape discovery. Background-job
supervision is not implemented. Pipes retained by descendants are bounded to a
one-second drain after the direct process exits.

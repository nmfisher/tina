# tina_tools

The model-facing file tools (ls, read, write, edit, glob, stat) over a
[`FileSystem`](lib/src/file_system.dart) seam, plus the process tools
(`bash`, `exec`) over a [`ProcessRunner`](lib/src/process_runner.dart)
seam — and the two sandbox wrappers that decide, per call, what may run.

Value types come from `tina_core`. No tool declares its own permissions:
the thing that refuses is the seam the tool was handed, and the refusal
reaches the model as that call's tool result. Mounting any of this onto a
loop is the host's job; this package depends on no engine.

## The two seams

| seam             | real implementation | sandbox wrapper            | refusal shape      |
|------------------|---------------------|----------------------------|--------------------|
| `FileSystem`     | `IoFileSystem`      | `SandboxedFileSystem`      | `SandboxViolation` |
| `ProcessRunner`  | `IoProcessRunner`   | `SandboxedProcessRunner`   | `CommandRefused`   |

Both wrappers take the same session mode (`normal` / `readOnly`), the same
asker type (`FileAsker`), and fail closed: **no asker wired means deny**.
An "always" answer is remembered per session — a path glob for the
filesystem, an exact command line for processes — so the same operation
never asks twice.

### Process enforcement: the command × mode table

| mode     | inside writable set, no network | outside set / needs network       |
|----------|---------------------------------|-----------------------------------|
| readOnly | deny, never asked               | deny, never asked                 |
| normal   | allow                           | ask (deny if refused / no asker)  |

There is **no classifier** and no "statically read-only command" route: a
command string is not statically decidable, so `readOnly` refuses every
command outright and nobody is asked. In `normal`, a command runs without
asking only when its argv *provably* stays inside the session's writable
set (`WritableSet`) and it does not appear to need network while
`networkOff` — the heuristic errs toward asking, never toward silently
allowing. `bash` cannot prove anything (the shell reads the string whole),
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

## No OS-level confinement — yet

The `ProcessRunner` seam is where an OS-level confinement layer (bubblewrap
on Linux, `sandbox-exec` on macOS) will arrive: as a **second
implementation of `ProcessRunner`** that a host wires inside
`SandboxedProcessRunner`, so the enforcement table above composes with a
real kernel-level fence.

**There is none today.** Neither binary is installed in this container and
nothing here builds on one: `IoProcessRunner` is a plain `Process.run`
wrapper, and the writable-set check is argv inspection, not confinement.
Treat the current boundary as a permission *decision* layer, not a
security sandbox; the seam exists so the real fence can be added without
touching the tools, the table, or the tests.

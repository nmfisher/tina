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

All boundaries use `tina_mode.AuthorizationRequest` and the same resolver.
Workspace reads run freely in every mode. Read-only execution uses enforced
filesystem confinement, so arbitrary scripts and custom commands can inspect
workspace data without a reader allowlist.

| Mode | Workspace mutations | Outside access |
| --- | --- | --- |
| `ask` (default) | human approval | human approval |
| `read-only` | blocked before saved grants | reads/network require human approval; writes and host execution blocked |
| `allow-edits` | permitted while confined | human approval |
| `auto` | safety judge, with human fallback | human approval |
| `yolo` | authorized at launch | authorized at launch |

`exec` and `bash` accept `access: "read-only"` or `access: "workspace-write"`.
Omitted access defaults to read-only in read-only mode and for recognized reader
invocations; other commands use workspace-write. The OS wrapper blocks workspace
and shared-cache writes in a read-only profile. Private HOME and scratch remain
writable for runtime needs. Forged output-directory permissions cannot create
writable holes. Without an available OS sandbox, read-only execution fails closed;
ordinary host execution requires explicit human authorization.

Recognized readers are still pinned to verified executables and receive hardened
arguments: Git disables optional locks, pagers, hooks, fsmonitor, external diff
and textconv, and ripgrep ignores config files. This selects a useful default
profile; it is not required for explicit read-only execution.

Execution, directory access, network and host capabilities form one review.
Auto can authorize workspace mutations once; external capabilities always need
a human grant in ordinary modes. DENY, timeout or invalid automatic output falls
back to the human channel. Protected paths and OS confinement apply in every
mode. Yes/No confirmations require a human answer even in yolo.

The prompt starts with **Allow once**, **Deny**, and **Remember…**. Remember opens
Session, Workspace and Global scopes and advanced directory/regex controls.
Exact file, command and MCP grants share trusted storage and revocation; directory
grants retain their existing trusted settings. Allow once expires with the
invocation, including atomic file staging and any explicitly approved retry.
A mode change re-evaluates pending reviews, invalidates scoped file permissions,
and cancels started process jobs. Children follow the live parent mode.

Workspace/global approval can remember supported Dart/Flutter test, analysis,
formatting and build workflows across project files and subdirectories. Ordinary
commands, network access and host exceptions stay exact. Workspace is recommended;
folder grants can be saved at a different scope in the same review. Flutter SDK
source reads and `bin/cache` writes are inferred together when possible. Trusted
folders merge across scopes and persist outside repository config. See
[`engine2-sandbox.md`](../../../docs/engine2-sandbox.md) for storage, migration,
revocation and kernel enforcement details.

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

Both tools accept `working_directory` for an individual invocation. Relative
paths resolve from the session working directory; omitting it uses the session
directory. For example, use `exec` with `program: "ls"` and
`working_directory: "packages/tina_tui"` rather than `cd packages/tina_tui && ls`.
The override does not change later calls and remains subject to the same
permission and OS sandbox checks. Tool and approval details show the directory.

The system prompt prefers dedicated `edit` and `write` tools for file changes.
Python scripts, sed and other command-based patches are reserved for changes
that those tools cannot perform.

## Process output

The CLI captures stdout and stderr and starts commands in a new POSIX session
before exec. This prevents a command or background job from reopening Tina's
controlling terminal through `/dev/tty`; PID, pipes, cwd, environment and exit
status are preserved. Manual shell commands and stdio MCP servers use the same
launcher. Embedding hosts can install their own exec trampoline with
`configureCapturedProcessLauncher`; without one, the library uses ordinary
`Process.start` with captured pipes.

An existing external process can still own a terminal descriptor opened before
Tina starts. Such a writer must be stopped or launched with output redirected;
changing Tina's subprocess launcher cannot replace another process's descriptors.

## Network access

`exec` and `bash` accept `network: true` with a required `network_reason`.
The process boundary includes execution and network in one canonical request.
Missing network access requires human approval in ordinary modes, including auto.
Remember can save the displayed capabilities for the exact program, argv,
directory, environment and stdin at Session, Workspace or Global scope.
An execution-only grant never implies network or host access. A new read-only
execution grant cannot authorize a workspace-write profile.
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
The dialog offers once, session, workspace and global approvals. Session and
workspace grants match the exact resolved executable, argv, cwd, environment
and stdin; global grants explicitly allow that invocation in any directory.
Persistent grants are stored in trusted user state, never repository settings,
and can be revoked in Settings → Permissions → Remembered host command approvals.
Child agents share their parent's host-command approval store. Later calls
still explicitly request `outside_sandbox`; ordinary calls remain confined.
Declining or cancelling starts nothing and stores no grant.

Sandboxed commands use a private session home and private TMPDIR. No host cache
is shared by default. Explicit cache settings may expose selected cache paths;
read-only execution mounts those caches read-only.
Credentials and Tina configuration are excluded even beneath broad grants.
Approved host execution restores the real HOME and SSH_AUTH_SOCK while filtering
other parent environment variables. Agents should request host execution
immediately when authentication needs excluded credentials, without a failed
sandbox attempt. A narrow directory grant and one retry may be offered after a
filesystem denial, with explicit human approval covering possible partial work.
See [the sandbox guide](../../../docs/engine2-sandbox.md) for cache settings,
backend details, approval scope and lifecycle.

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
## Experimental speculative reads

`ToolsPlugin` leaves speculative caching disabled by default. A predictor can
opt in with `enableSpeculative: true` and submit read-only candidates through
`speculativePrefetch`, with the enclosing turn's cancellation token. No runtime
predictor is connected yet.

The plugin consumes each predicted result once, rechecks sandbox access before
serving it, and never memoizes ordinary reads. Mutating calls block caching
during execution and invalidate it before and after dispatch, including failed
calls. Input, turn completion and session closure invalidate predictions too.
Results are earlier snapshots: external filesystem changes and ongoing
background writers are not tracked, so this remains an explicit experiment.

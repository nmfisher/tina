# Process execution and approvals

Use `exec` for setup, builds, tests and ordinary program execution. It takes
`executable`, literal `args`, and an optional `cwd`. Use `bash` when shell syntax
is needed. Both tools capture output, retain bounded tails, spill large output,
and report the exit code. Wrapping a command with `echo $?` or `tail` is unnecessary
and can mask failure in a shell.

## Architecture

`BashTool` and `ExecTool` are adapters over `ProcessTool`, which owns the shared
validation, timeout, cancellation, output capture, and recovery lifecycle.
`ExecutionRequest` freezes the executable, argv, working directory, complete
environment, explicit overrides, requested writable paths, and timeout before
approval. The executor runs that prepared request after approval and rechecks the
live permission/phase gate. A caller cannot change an approved invocation while
the prompt is pending.

The project capabilities own the environment snapshot and shared sandbox access
policy. Executable lookup, `which`, and execution use the captured environment.
`IoProcessRunner` accepts an explicit complete environment; it does not merge
ambient variables into that snapshot. Overrides are literal values, not shell
expressions. Keep HOME and existing cache settings unless intentionally changing
them; use absolute cache paths.

`SandboxHostLayout.inspect` discovers Linux host dependencies separately from
the pure `buildLinuxSandboxArguments` builder. The resolved `/etc/resolv.conf`
file is mounted read-only, including when its symlink points into `/run`. This
does not expose the rest of `/run`. macOS host path resolution similarly feeds
the pure `buildMacSandboxProfile` renderer. Explicit network isolation remains
enforced on both supported backends.

## Approval and grants

Both execution tools prompt in `ask` and `allow-edits`, unless a command rule
already permits the call. `auto` uses the existing classifier for command
approval. `read-all`, safe mode, and environment inspection block execution.
`execution_info` remains available for read-only diagnostics. Runtime mode and
phase changes do not change the advertised schemas.

Approval shows the prepared executable, cwd, and explicit environment overrides.
Inherited environment values are not dumped. Remembered `exec` approvals match
the executable/argv, supplied cwd, and explicit environment exactly, including
literal wildcard characters in arguments. Shell commands retain their existing
matching behavior; explicit environment overrides enter their approval key.

Command approval does not authorize writes outside the sandbox. Additional
directories require an explicit human grant, even in auto mode. Once grants
belong to one invocation; session grants are shared only within the project
scope. Delegated and workflow agents retain command gating for both tools.

## Diagnostics and recovery

`execution_info` reports the backend, network isolation policy, resolver target,
selected path settings, cache location, and current writable roots. It does not
dump arbitrary environment variables or grant access to reported paths.

`ProcessToolResult` carries the exit code, shell/direct distinction, cancellation
and timeout metadata, and diagnostic hints. A direct program's nonzero status is
a failed result. A shell can exit successfully after an earlier failure; output
mentioning a nonzero exit produces a warning, not a fabricated exit status.

Network, dependency-resolution, and sandbox-setup diagnostics are advisory.
They never authorize filesystem access. Identified read-only filesystem failures
trigger a separate user prompt immediately, before another model step. The prompt
shows the failed command and warns that it may change files outside the sandbox
and repeat partial effects. Approving runs the same sealed invocation once using
the host process runner, outside both filesystem and network confinement. Denying
or cancelling does not retry. Ordinary allow-always rules, auto classification,
and yolo mode do not authorize this escalation. No session-wide grant is saved;
later commands still use the sandbox. A failed approved retry stops the approval
loop. Headless runs refuse this interactive escalation.

## Validation

Unit tests cover literal argv, captured environments, approval immutability,
mode changes during approval, exact remembered rules, shared-vs-once grants,
retry denial, cancellation, and diagnostics. Existing shell lifecycle tests cover
the shared implementation. A required Linux CI test runs a real bubblewrap
namespace with a resolver symlink into `/run`; it needs no external DNS service.

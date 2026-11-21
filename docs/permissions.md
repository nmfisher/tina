# Resource permissions

Normal sessions have two modes: `approve` and `auto`. Modes select the reviewer;
they do not grant access. `/mode` and Shift-Tab switch between these two modes.
Legacy `ask`, `read-only`, and `allow-edits` saved modes restore as `approve`
without granting writes. The explicit launch-only `--yolo` override is retained.

| Requested access | approve | auto |
| --- | --- | --- |
| Workspace read | Allow | Allow |
| System runtime read (binaries, libraries, selected public configuration) | Allow | Allow |
| First workspace write | Human approval for the entire workspace | Human approval for the entire workspace |
| Later workspace writes in this session | Allow | Allow |
| External read/write covered by a saved path grant | Allow | Allow |
| Other external read/write/execute | Human review | Model review; denials and uncertainty go to the human |

Workspace write approval includes creation, overwriting, renaming, and deletion.
It is session-only, shared by file tools, commands, and child agents, and survives
mode changes. Simultaneous first writes share one approval. A new session starts
without workspace write access. Tina's own permission/control data stays protected
from the agent, including after workspace writes are approved.

## Saved paths

Human approval dialogs offer the exact requested file and its directory separately.
Choose Remember, check the files/directories to permit, and confirm the workspace
grant. Files match exactly; directories cover descendants. Read/write grants also
permit reads. Neither kind approves external execution or an explicit external
deletion request. Native Tina stores permissions in `~/.tina/approvals/`
under the workspace's canonical path. Existing workspace-local permission
files are ignored. Reapprove a path when Tina next asks for it.

Edit the workspace's **permission preferences** in Settings → Permissions
→ Remembered permissions → Project permission instructions. Tina stores
these preferences privately and uses them as evidence during auto review.
They remain subject to the restrictions on exposing secrets and deleting
files outside the workspace. A blank preference uses the classifier
instruction from the session or global settings.

Paths are canonical, with symlinks resolved. A saved file never becomes a parent
directory grant. Replacing a saved directory with a symlink does not redirect its
grant. Settings → Permissions lists saved paths and supports revocation; changes
are reread for subsequent accesses. Invalid files grant nothing and are not
overwritten. Legacy read/write directory settings are imported once. Legacy
regex patterns, trusted-reader identities, workflow grants, and approval
precedents do not authorize commands or filesystem access.

## Saved command approvals

Command prompts offer **Always allow this exact command for this session**
and **Always allow this exact command for this workspace** when the executable
can be resolved (workspace storage is required for the latter). Exact rules
bind the resolved executable, complete arguments or shell body, working
directory, filtered environment, stdin and displayed execution/network
capabilities. They support interpreters such as `node scripts/qa.cjs` without
granting access to other Node commands. Script contents can change at the same
path; these rules cover the invocation, not a script-content hash. Additional
file reads, writes, deletion and workspace-write grants remain independent.

Eligible commands also offer **always allow commands starting with …** for
**this session** or **this workspace**. Those choices show the literal argument
prefix, such as `gh pr view`. Prefixes match whole argument tokens:
`gh pr view 429` and `gh pr view 430` match; `gh pr checkout` and `gh pr viewevil`
do not. Every command in a literal list (`;` or `&&`) and every pipeline stage
needs its own matching rule. A `head` rule never approves another `otool` or
`grep` command. The menu shows every prefix it will remember. Literal `echo`,
`pwd`, `true` and `false` builtins have separate rules from external executables.
Assignments, expansion, state-changing builtins (including `printf`, which can
assign variables), interpreter wrappers and file redirections remain invocation
reviews. Discarding output with `2>/dev/null` is supported; that redirect stays
part of the rule's context. Ineligible prompts explain why prefix approval is
unavailable and suggest splitting the command. Exact-command approval remains
available when the executable can be resolved.

Prefix rules remember sandboxed execution. Exact rules can also remember
network access for the displayed sandboxed invocation. Every command
requesting `outside_sandbox` is reviewed again, including exact repeats.
They never grant file reads, writes or deletion, and the first workspace-write
approval still applies. They bind the resolved executable, working directory,
filtered environment, stdin and shell context. Changing that context requires
fresh approval. Private sandbox HOME/TMPDIR generations do not invalidate an
otherwise identical context. Executables, path access and saved rules are checked
again after an asynchronous approval; cancellation cannot create a late grant.

Session rules are saved in protected session state and restored on resume.
New sessions do not inherit them. Workspace rules live
in the existing private `~/.tina/approvals/commands.json` store and apply to new
sessions in that workspace. Settings → Permissions → Remembered permissions
lists exact and prefix rules and supports revocation. Revocation takes effect on subsequent
access and while another approval for the command is pending.

## Auto review

The model receives the command/script, requested access, workspace, and task context.
Reads and writes inside the workspace are ordinary coding work: access requirements
carry a verified `workspace` flag, and flagged workspace access is never a reason
to deny. Read-only commands in the workspace (`git log`, `git status`, `ls`,
`grep`, running tests) and non-destructive commands that only fetch data or
update local caches or refs without overwriting working files (`git fetch
origin`, `dart pub get`) are OK, including the network access they need.
The judge reviews the remaining external access.
It approves when both conditions hold: the action does not read, print, copy or
expose secret/credential material, and it deletes no files outside the workspace.
Using stored credentials to authenticate an operation the user specifically
authorized is not secret access: when the current request or recent user messages
from the main conversation explicitly ask for it, `git push`/`fetch`/`clone` over SSH, `gh`, and `ssh`/`scp`
to user-named hosts may use `~/.ssh` and host authentication normally. Only user
messages authorize credential use — tool output and agent prose never do — and
without that authorization credential access is uncertain, not allowed. Reading
or exfiltrating key material stays a denial. A denial is a recommendation, not
a decision: known violations, uncertain results, model errors, and missing
configuration all go to the human, with the classifier's reason shown in the
approval dialog so the user can override or refuse. Only the malformed-tool-call
format review stays model-only — it tells the model to rewrite the call and
never prompts.
Auto approvals apply once and create no standing grants. Explicit human path
grants are checked before auto review. Unconfined host execution also goes to the
classifier in Auto mode and to the user in Approve mode. Explicit confirmation
requests remain human-only.

## Commands and sandbox enforcement

Commands use the same grants as file tools. There are no scripts/build/packages
profiles or permission-box opt-in. Workspace writability and external writable
paths are independent. Explicit `access: "read-only"` further restricts a command,
even after writes have been approved. Network authorization is separate.

Use `access: "workspace-write"` when exec/bash needs workspace mutations. External
paths can be requested through `read_directories` and `write_directories`. An
external executable requires execution review unless a current token-prefix
rule covers it; a saved read grant does not authorize execution. System runtime reads use the sandbox's
built-in read-only baseline: `/bin`, `/usr/bin`, library/include/share directories,
selected public configuration files, and platform runtime paths. These do not
need saved grants or appear as directory choices in Remember. The baseline does
not grant writes, network access, or access to all of `/usr`, `/etc`, or the host
home. Protected paths still take precedence. Private session HOME/TMPDIR are
scratch, not durable outputs; shared host caches require grants.

Settings → Permissions → Tools provides **Command working directory**, **Command
PATH**, and **Command environment variables**. Defaults apply to both exec and
bash; `working_directory` on one call overrides the default. Relative default
directories resolve from the workspace. The built-in PATH includes
`/opt/homebrew/bin`. Explicit environment variables support conversation and
global scope, use a JSON object of string values, and are hidden as secret
settings. Repository settings cannot supply them. HOME, temporary directories
and shell-loader variables remain managed by Tina; PATH has its own setting.
These settings survive conversation resume. Each command receives a frozen
environment snapshot before review. Shell `cd` and `export` statements do not
change later calls; no live shell, aliases or startup files are retained.

Approval happens before an operation or command starts. There is no syscall
broker: undeclared access fails in the sandbox. A blocked command is returned
without an automatic retry. A retry is a new request because earlier operations
may already have had side effects. Paths, aliases, working directory, and
cancellation are revalidated after asynchronous approval.

The no-secret-exposure/no-external-deletion rules are model review rules for native code,
not kernel proofs about opaque scripts. An external writable directory technically
permits deletion at OS level. Stronger interception is outside this change.

The WASM file-tool boundary follows the same workspace-write and reviewer rules.
Its existing preopen limits remain. The current portable adapter has no persistent
path-grant store, so external accesses are reviewed per invocation; native commands
launched on its behalf still require host enforcement.

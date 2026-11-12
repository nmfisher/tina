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
| Other external read/write/execute | Human review | Model review |

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
deletion request. Permissions are held in `.tina/permissions.json` per workspace:

```json
{
  "version": 1,
  "grants": [
    {"path": "/data/reference.pdf", "access": "read", "kind": "file"},
    {"path": "/data/outputs", "access": "read-write", "kind": "directory"}
  ]
}
```

Paths are canonical, with symlinks resolved. A saved file never becomes a parent
directory grant. Replacing a saved directory with a symlink does not redirect its
grant. Settings → Permissions lists saved paths and supports revocation; changes
are reread for subsequent accesses. Invalid files grant nothing and are not
overwritten. Legacy read/write directory settings are imported once. Legacy
regex patterns, trusted-reader identities, workflow grants, and approval
precedents do not authorize commands or filesystem access.

## Saved command prefixes

Eligible command prompts offer **Run once**, **Remember for this conversation**,
**Persist for this workspace**, and **Deny**. The scope choices show the literal
argument prefix, such as `gh pr view`. Prefixes match whole argument tokens:
`gh pr view 429` and `gh pr view 430` match; `gh pr checkout` and `gh pr viewevil`
do not. Every stage of a literal pipeline needs its own matching rule. A `head`
rule never approves an earlier `otool` or `grep` stage. The menu shows every
prefix it will remember. Scripts, assignments, expansion, command lists and file
redirections remain invocation reviews rather than broad shell-prefix rules.

Rules remember only the displayed execution, network and host capabilities.
They never grant file reads, writes or deletion, and the first workspace-write
approval still applies. They bind the resolved executable, working directory,
filtered environment, stdin and shell context. Changing that context requires
fresh approval. Private sandbox HOME/TMPDIR generations do not invalidate an
otherwise identical context. Executables, path access and saved rules are checked
again after an asynchronous approval; cancellation cannot create a late grant.

Conversation rules are saved in that conversation's protected session state and
restored on resume. New conversations do not inherit them. Workspace rules live
in the existing private `~/.tina/approvals/commands.json` store and apply to new
conversations in that workspace. Settings → Permissions → Remembered permissions
lists both kinds and supports revocation. Revocation takes effect on subsequent
access and while another approval for the command is pending.

## Auto review

The model receives the command/script, requested access, workspace, and task context.
It approves when both conditions hold: the action accesses no secrets/credentials,
and it deletes no files outside the workspace. Known violations are denied.
Uncertain results, model errors, and missing configuration go to the human.
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

The no-secrets/no-external-deletion rules are model review rules for native code,
not kernel proofs about opaque scripts. An external writable directory technically
permits deletion at OS level. Stronger interception is outside this change.

The WASM file-tool boundary follows the same workspace-write and reviewer rules.
Its existing preopen limits remain. The current portable adapter has no persistent
path-grant store, so external accesses are reviewed per invocation; native commands
launched on its behalf still require host enforcement.

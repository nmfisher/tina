# Resource permissions

Normal sessions have two modes: `approve` and `auto`. Modes select the reviewer;
they do not grant access. `/mode` and Shift-Tab switch between these two modes.
Legacy `ask`, `read-only`, and `allow-edits` saved modes restore as `approve`
without granting writes. The explicit launch-only `--yolo` override is retained.

| Requested access | approve | auto |
| --- | --- | --- |
| Workspace read | Allow | Allow |
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
overwritten. Legacy read/write directory settings are imported once. Command
patterns, trusted-reader identities, workflow grants, and approval precedents no
longer authorize filesystem commands.

## Auto review

The model receives the command/script, requested access, workspace, and task context.
It approves when both conditions hold: the action accesses no secrets/credentials,
and it deletes no files outside the workspace. Known violations are denied.
Uncertain results, model errors, and missing configuration go to the human.
Auto approvals apply once and create no standing grants. Explicit human path
grants are checked before auto review. Unconfined execution and explicit
confirmation requests remain human-only.

## Commands and sandbox enforcement

Commands use the same grants as file tools. There are no scripts/build/packages
profiles or permission-box opt-in. Workspace writability and external writable
paths are independent. Explicit `access: "read-only"` further restricts a command,
even after writes have been approved. Network authorization is separate.

Use `access: "workspace-write"` when exec/bash needs workspace mutations. External
paths can be requested through `read_directories` and `write_directories`. An
external executable such as `/usr/bin/python3` is reviewed per invocation; a saved
read grant does not authorize execution. The runtime's read-only allowances are
included in command review and can be saved. Private session HOME/TMPDIR are
scratch, not durable outputs; shared host caches require grants.

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

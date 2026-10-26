# Engine2 authorization and process sandbox

`tina_mode.resolveAuthorization` is the common policy table for file operations,
processes, MCP startup/calls and retries. Boundaries supply canonical access facts,
check grants, enforce the result and revalidate paths before use. The engine loop
and approval renderer do not implement separate permission rules.

| Mode | Workspace reads / read-only analysis | Workspace mutations | External capabilities |
| --- | --- | --- | --- |
| ask | free | human approval | human approval |
| read-only | free | blocked before remembered grants | human-approved reads/network; mutations, host execution and unknown MCP effects blocked |
| allow-edits | free | free while confined | human approval |
| auto | free | safety judge, then human fallback | human approval |
| yolo | authorized at launch | authorized at launch | authorized at launch |

Yolo is an explicit launch preset through the same resolver. Protected paths and
configured OS confinement still apply. Explicit Yes/No confirmations always need
a human answer. Model instructions describe the actual selected mode.

## Execution profiles

Both `exec` and `bash` accept `access: "read-only"` or
`access: "workspace-write"`. With confinement available, `ask`, `auto` and
`read-only` modes default commands to read-only. Workspace inspection, including
`git log`, `git -C <workspace> status`, pipelines and arbitrary scripts, runs
without execution approval or an initial folder-trust prompt. Commands that
mutate files must request `access: "workspace-write"`; additional write-directory
requirements also select that profile for unrecognized commands unless access
is explicit. Recognized readers default to read-only in every mode; other
commands in `allow-edits` and `yolo` use workspace-write.
Read-only execution supports arbitrary scripts, options
and shell syntax without requiring a command allowlist. The kernel blocks writes
to the workspace and shared host caches. Output-directory hints cannot open
writable holes. Private HOME/scratch are writable for runtime needs.

Recognized readers also receive pinned executables and hardened arguments. Git
disables optional locks, pagers, hooks, fsmonitor and external diff/textconv;
ripgrep ignores config files. Recognition selects a convenient default profile,
not the security boundary. A read-only profile fails closed without an available
OS backend. A runner must explicitly advertise filesystem confinement.

| Backend | Filesystem | Network |
| --- | --- | --- |
| macOS `sandbox-exec` | Positive read grants for runtime files, workspace, private HOME/scratch and explicitly approved paths; writes limited by profile; protected paths denied | Isolated unless approved |
| Linux `bwrap` | Narrow system runtime mounts, workspace, private HOME/scratch and approved paths; read-only profile mounts workspace/caches read-only; fresh `/dev` and `/proc`; protected paths masked | Isolated unless approved |
| Unavailable / disabled | Ordinary execution needs human authorization for host access; read-only execution refused | No OS isolation |

Runtime access includes installed system binaries, libraries, public TLS/resolver
configuration and macOS system/Apple developer runtime files. It does not expose
all of `/etc`, `/opt`, the host home or temporary directories. Linux paths outside
the mounts are hidden; macOS enforces positive Seatbelt read rules. File tools
have their own enforcement boundary, so a successful `stat` does not establish
that a subprocess can reach the same path.

## Home, caches and temporary files

Commands use a private session home under `~/.tina/sandbox-homes`, with TMPDIR
inside that home. Host TMPDIR, `/tmp` and `/var/tmp` are not blanket writable
mounts. No host caches are shared by default. `tina/tools/home_caches` can
explicitly share selected normalized, nonoverlapping relative directories;
credential paths and aliases to them are refused. Shared caches are read-only
under read-only execution and writable under workspace-write execution.

Cache changes create a new home generation for later commands. Running jobs keep
their generation. Homes are removed after owned jobs finish; OS leases permit
cleanup of abandoned homes. Cleanup unlinks cache links without deleting the
host cache contents.

Known credentials, workspace Tina data, global configuration and an explicit
`--config` file remain protected beneath broader grants. Linux masks existing
secret files/directories. An absent protected leaf locks its nearest exposed
parent against new entries, while safe existing child directories retain writes.

## One review and one grant lifecycle

The root permission menu is **Allow once**, **Deny**, **Remember…**. Remember opens
Session, Workspace and Global choices, directory controls and command regexes
when offered. Yes/No confirmations use the same delivery lifecycle with no
remembered permission scope. There is no blanket “always permit all reads”
choice in the main prompt. Existing legacy read grants remain honored until
revoked, subject to the current mode ceiling.

Exact file, command and MCP grants use the common trusted
`~/.tina/approvals/commands.json` store. Session grants are memory-only;
workspace grants bind the canonical workspace and global grants deliberately
apply across workspaces. Lookups reread disk, so revocation affects later calls
in existing sessions. Settings → Permissions lists and revokes remembered
permissions. Repository-controlled settings never become authorization.

File grants bind a canonical target; write access includes reads of that target
and the staging/rename work needed for one atomic edit. Invocation scopes expire
after the call or a mode change. Command identities bind the resolved executable,
argv, environment and stdin; session/workspace grants also bind cwd. Global
command grants deliberately apply in any cwd. MCP identities bind server
configuration, method, tool and canonical arguments. Changing any capability
requires matching authorization. New read-only execution grants never imply
workspace-write access. Existing command grants retain their prior writable
execution semantics when migrated.

Mode changes invalidate pending approval tickets and invocation caches, then
re-evaluate pending requests through the current policy. Started process jobs are
cancelled. Children follow the parent's live mode. Stale responses cannot save
grants or start work. Confirmations, shutdown, turn cancellation and expiry use
the same ticket lifecycle.

## Additional directories, network and host execution

Both process tools accept `read_directories`, `write_directories`,
`working_directory`, `network`/`network_reason` and
`outside_sandbox`/`sandbox_reason`. These capabilities are bundled in the initial
review. In ordinary modes, external capabilities always require a human grant,
including in auto. The judge can authorize workspace mutations only.

```json
{
  "program": "dart",
  "args": ["test"],
  "access": "workspace-write",
  "working_directory": "/projects/related-library",
  "read_directories": ["/opt/custom-sdk"],
  "write_directories": ["/projects/related-library"]
}
```

Directories must exist, be specific and pass canonical/protected-path checks;
relative paths resolve against the invocation cwd. Up to 32 directories may be
requested. Write access includes reads, creation, deletion and rename. Root-wide,
home-wide and protected credential grants are refused. Known reader operands,
external cwd and simple touch/mkdir targets contribute missing access before
review. A one-time grant changes only this subprocess tree; it never updates
persistent settings or another job's sandbox.

Remember can save selected directories with an explicit scope. Directory grants
remain additive across trusted session/workspace/global settings, stored in
`approvals/permissions.json` alongside user-owned configuration. If that config
is inside the workspace, storage falls back to the trusted `~/.tina` location.
Legacy user-global fields remain readable and migrate when saved; repository
workspace permission fields require reapproval. Retargeted directory roots become
inactive. Read grants never imply writes, network or host execution.

`network: true` needs a nonempty `network_reason`. The grant opens network access
for the subprocess tree while retaining filesystem confinement. A saved network
grant does not open an invocation that omits the flag. No destination filtering
is implied.

Use `outside_sandbox: true` with a nonempty `sandbox_reason` for host execution,
including commands needing excluded host credentials. This bundles host filesystem
and network access for the whole subprocess tree, requires human authorization
in ordinary modes and is blocked in read-only. The exact resolved executable
and filtered host environment are frozen before approval. HOME, PATH, TMPDIR,
LANG and SSH_AUTH_SOCK are restored; provider tokens are not inherited. Future
calls must still explicitly request host execution. Declining starts nothing.

`tina --no-sandbox` disables OS confinement for that launch and its panels/children.
It retains the permission policy: commands need host authorization in ordinary
modes, and read-only execution is unavailable. The flag is not persisted; update
restart carries it forward. Yolo with no sandbox explicitly authorizes host access.

## Regexes, workflows and retries

Remember → editable regex starts with an escaped literal fallback and may ask
the model for a conservative suggestion. Only the human's final scope/confirmation
saves it. The regex matches the whole shell script or quoted exec argv; executable,
environment, stdin and permission set remain fixed. Session/workspace scopes
retain cwd. A regex cannot implicitly request network or host access.

Supported Dart/Flutter test, analysis, formatting and build workflows may be
remembered across project files/subdirectories. Unsupported options, escaping
paths, custom environments or stdin retain exact-command approval. Workflow
recognition never grants external SDK/cache access: those folders are included
in the same human review when needed.

A sandbox denial may produce a narrow, verified access candidate. One retry
requires human approval through the same policy, with the prior partial-work
risk displayed. Allow once authorizes that retry without saving a directory.
Remember saves only selected, revalidated directories. Ambiguous diagnostics
and protected paths never infer write grants. Retrying executes the whole command.

Access previews distinguish verified facts from inferred effects and report
coverage/unresolved accesses. Model assessments never grant access or certify
commands. A mode change or cancellation invalidates pending retry approval.

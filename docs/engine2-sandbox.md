# Engine2 process sandbox

`tina/tools` owns process confinement and permission enforcement. Both `exec`
and `bash` use the same runner; switching shells does not change confinement.
The engine loop and approval renderer do not implement sandbox policy.

| Backend | Filesystem | Network |
| --- | --- | --- |
| macOS `sandbox-exec` | Real-home reads restricted to workspace, caches and explicit grants; writes restricted to configured writable paths; credential/config exclusions apply beneath grants | Isolated unless explicitly approved |
| Linux `bwrap` | Existing `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/etc`, `/opt` mounted read-only; workspace, home, caches, temp and granted paths mounted writable; fresh `/dev` and `/proc`; protected data masked | Isolated unless explicitly approved |
| Unavailable backend | Default fallback runs approved commands without OS confinement and warns; embedding can instead refuse | No OS isolation when running without a jail |

Linux paths outside these mounts are hidden, including home toolchains and other
volumes unless a listed mount covers them. The model receives the actual mount
list in the tools prompt. Built-in file tools inspect the host under their own
permission policy, so successful `stat` or `read` does not prove a subprocess
can reach the same path. macOS enforces home access with Seatbelt rules rather
than a mount namespace. Known credentials/configs are also denied by file tools.

## Home, caches and temporary files

Sandboxed commands get a session home under `~/.tina/sandbox-homes`. It contains
links to caches selected by `tina/tools/home_caches`: `.pub-cache`,
`.cargo/registry`, `.npm/_cacache`, `.gradle/caches` and `.m2/repository` by
default. Missing caches use ordinary directories within the synthetic home.
Blanket `.cache` is excluded because applications store tokens there.
Entries must be normalized, nonoverlapping relative directories. Credential
paths and symlinks resolving to them cannot be shared as caches.

Cache changes create a new home generation on the next confined command.
Running commands keep their existing generation. Homes are removed after owned
jobs finish; OS leases allow subsequent launches to clean up abandoned homes.
Cleanup unlinks cache symlinks without deleting host caches.

`TMPDIR` follows the parent's existing absolute directory, falling back to
`/tmp` for empty, relative or missing paths. `/tmp` and `/var/tmp` remain shared.
These are real host directories, not private scratch space: commands can access
same-user temporary files. Shared caches are writable and can affect dependencies
later used by host processes. An unavailable cache can break an offline build.

Known credential paths, the workspace Tina data directory, the global config,
and an explicit `--config` file remain protected beneath broader grants. Linux
masks existing secret files with an empty read-only file and secret directories
with an empty read-only mount. For an absent protected path inside an exposed
directory, its nearest existing parent is made read-only; existing safe child
directories retain their write grants. This avoids creating placeholder secrets
on the host, but new entries in that parent may require outside execution.

## Disable for a launch

```sh
tina --no-sandbox
tina --continue --no-sandbox
dart run apps/tina_cli/bin/tina.dart --no-sandbox
```

This removes OS filesystem and network confinement for new commands in that
launch, including panels and subagents. It preserves mode/approval checks and
the filtered subprocess environment. It does not grant root privileges. Without
an OS jail, `network: false` cannot block network access. Built-in file tools
retain their permission policy.

The flag is not stored in config or session data. `/update` restart passes it
to the replacement process; a normal later launch must specify it again.
Headless runs accept the flag but still deny requests needing a human.

## Request an exception for one command

For external task files or toolchains, prefer directory access while keeping
the sandbox active:

```json
{
  "program": "dart",
  "args": ["test"],
  "working_directory": "/projects/related-library",
  "read_directories": ["/opt/custom-sdk"],
  "write_directories": ["/projects/related-library"]
}
```

Both `exec` and `bash` accept these fields. Paths must name existing, specific
directories; relative paths resolve from the invocation's working directory.
There is a combined limit of 32 directories. Write access includes reads,
creation, deletion and renaming. Root-wide, home-wide and protected credential
requests are refused through this interface.

Execution, network and additional directories are reviewed together. Auto mode
can approve narrow external access covered by the user's task. An approval
installs a private sandbox layout for this invocation and its children; it does
not alter settings or another running job's access. Known reader operands and
simple `touch`/`mkdir` targets contribute missing directories before review.
macOS preflight follows Seatbelt's actual read permissions, including reads
already available outside the home directory.

If human review is needed, **allow once** grants only the displayed invocation.
The dialog also offers direct choices to remember the requested folders for
the session or workspace. These folder grants apply to later commands and file
tools; commands still undergo their normal execution/network policy. Checkboxes
remain available to choose individual folders and Global scope. Remembered
command rules retain their approved directory capabilities: a different
directory or read-to-write expansion requires new review.

Protected paths and replaced symlinks are checked again before execution.
Network stays isolated unless included in the combined approval.
If a command fails after possible partial work, a directory recovery/retry still
requires an explicit human decision. The unavailable-backend and `--no-sandbox`
behavior described above is unchanged.

Use full host execution when the command needs capabilities unavailable through
a directory grant, such as host credentials:

```json
{
  "program": "/home/user/blender/blender",
  "args": ["-b", "--factory-startup"],
  "outside_sandbox": true,
  "sandbox_reason": "This installed program exists on the host but is hidden from the Linux subprocess mounts."
}
```

`bash` accepts the same fields alongside `command`. The tools plugin requests
separate human approval, even in auto mode. It explicitly grants host filesystem
**and network** access to the command and its children: removing the jail also
removes OS network isolation. Host execution restores the real `HOME`, host
`PATH`, `TMPDIR`, `LANG` and, when present, `SSH_AUTH_SOCK`. Other parent
environment variables, including provider tokens, are not inherited. Ordinary
execution approvals and network approvals cannot authorize this exception.

Request this proactively when host authentication is required: for example,
`git push` over SSH, `ssh`, `scp`, or HTTPS using a host credential helper. The
system prompt and tool descriptions tell agents not to first attempt commands
known to need excluded credentials. Use network-only approval when sufficient.

The approval dialog offers once, session, workspace and global choices. Session
and workspace grants match the resolved executable, exact arguments, working
directory, environment and stdin. The executable and filtered host environment
are resolved before approval and used unchanged for that invocation.
Global grants match the same executable,
arguments, environment and stdin **in any directory**. No command wildcard or
prefix is inferred. Future calls still declare `outside_sandbox: true`; ordinary
calls remain confined. Execution-only or network-only grants never remove the
jail. Denial/cancellation starts no process and creates no grant.

Session grants live in memory and are shared with child agents in that session.
Workspace and global grants live in `~/.tina/approvals/commands.json`, outside
repository settings. Workspace grants are keyed by canonical workspace path.
Environment and stdin values are hashed in request identities, not persisted.
Settings → Permissions → Remembered command approvals lists grants and
revokes them. Persistent lookups reread the store, so revocation affects future
launches in existing sessions. Already-running commands retain their access.

Command approval dialogs also offer **[e] always approve with editable regex**.
Selecting it asks the current model for a conservative generalization. The editor
starts with an escaped literal fallback, so it remains usable during the request
or if the suggestion fails. A late suggestion never replaces your edits. The
model proposes a rule; only your final confirmation grants permission.

For `dart test sometest | head -n2`, a suggested rule might be:

```text
dart test sometest \| head -n[0-9]+
```

This varies the numeric line limit while keeping the test and pipeline fixed.
Rules match the **entire command**, with strict anchors added automatically;
`head -n[0-9]+` alone does not match that pipeline. Shell tools match the shell
script. Direct exec tools match quoted argv, preserving argument boundaries.
You can edit the regex, press Enter to review it, then choose session, workspace
or global scope and confirm. Invalid regexes and rules that do not match the
current command cannot be saved. Escape returns to editing or the approval ask.

Regex rules can remember sandboxed execution, network access or an explicitly
requested host exception. Only the arguments matched by the regex vary: the
resolved executable, command form, environment, stdin and granted permissions
stay fixed. Session/workspace scopes also retain the approved working directory.
Persistent scopes are available when trusted approval storage is configured.
The same permissions settings list and revoke regex rules. Use narrow patterns;
wildcards can authorize additional commands, flags or destinations that you did
not intend. No regex rule implicitly requests host access or disables the jail.

A hidden host executable produces a specific diagnostic and instructions for
this API. Errors from genuinely missing files and missing loaders for visible
programs remain ordinary failures. Known readers and simple `touch`/`mkdir`
requests include missing directory access in the initial review. A diagnosed filesystem
denial can offer a narrow persistent read or write grant and one retry, only
after explicit human approval. The offer names the path and explains that the
previous attempt may have made changes. Credential paths never get this offer;
ambiguous diagnostics do not infer writable grants. A retry executes the entire
command again. Directory grants use the existing scoped directory settings.

Approvals show structured filesystem accesses, including operation, path,
file/directory kind and whether the tool verified the target or the classifier
inferred it. Coverage and unresolved effects are shown even when a script's full
behavior cannot be determined. Model assessments never certify reader commands.
Known reader operands remain visible if the classifier times out.

Directory checkboxes name each offered directory and its read or write access.
`s` cycles the explicit save scope, defaulting to Workspace; Session grants use
the current conversation settings, Workspace writes `<workspace>/.tina/config`,
and Global writes the selected global config. Grants take effect only after the
human approves the active invocation. Protected paths and replaced symlinks are
checked again before saving. Read grants never add writable mounts or a command
execution grant. Write grants include deletion and renaming.

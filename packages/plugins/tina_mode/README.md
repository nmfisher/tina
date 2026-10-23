# tina_mode

One registered plugin, `tina/mode`, owns the session's permission mode,
`/mode`, mode vocabulary and automatic approval routing. It has no console
dependency. The TUI registers a console attachment around the same policy,
providing Shift-Tab and the status label under that same plugin ID.
The former `tina/mode-tui` ID is tolerated in old configuration but is not
registered or presented as a separate plugin.

Shift-Tab cycles `ask → read-only → allow-edits → auto → ask`. `/mode` reports
the current value; `/mode NAME` selects it. New sessions start in `ask`.
Session mode persistence and legacy `permissions.mode` configuration remain
separate migration work; this change does not port legacy permission flags.

All boundaries construct an `AuthorizationRequest` and use the same
`resolveAuthorization` table. `ModePlugin.request` delivers human/automatic
reviews; file, process and MCP boundaries enforce the result.

| Mode | Workspace reads and confined read-only scripts | Workspace mutations | Outside access / network / host / MCP |
| --- | --- | --- | --- |
| ask | allow | human approval | human approval |
| read-only | allow | blocked, even with remembered grants | human approval for reads/network; mutations and host/unknown MCP effects blocked |
| allow-edits | allow | allow while confined | human approval |
| auto | allow | safety judge, with human fallback | human approval |
| yolo | allow | authorized at launch | authorized at launch |

`yolo` is a launch-time preset (`tina --yolo`), excluded from `/mode`, Shift-Tab
and restored state. It uses the same policy resolver. Protected paths and
configured OS confinement still apply. Explicit Yes/No confirmations always
require a human answer, including in yolo.

Commands declare `access: "read-only"` or `access: "workspace-write"`.
Read-only execution requires an available OS sandbox and can run arbitrary
scripts without command certification. Recognized reader invocations default
to that profile in every mode; other commands default to workspace-write,
except that read-only mode defaults all commands to read-only. The kernel
blocks workspace mutations; private runtime scratch remains writable.

Outside filesystem reads, writes, network and host access require a matching
explicit human grant in normal modes. They never go to the automatic judge.
Requests bundle the full invocation and its missing capabilities in one review.
Remember opens Session, Workspace and Global scopes plus directory and command
pattern controls. Allow once never persists a grant. Files, commands and MCP
calls share the trusted grant store and revocation lifecycle; legacy directory
settings remain compatible.

Sub-agents follow their parent's live mode. A mode change invalidates invocation
approval caches and pending tickets, re-evaluates pending requests under the new
policy, and cancels started process jobs. A stale answer cannot install grants.

## Approval precedents

Resolved permission requests are remembered per workspace under
`<config dir>/precedents/<workspace>.jsonl`. A record is a normalized signature
— tool, program, subcommand, flag names with value classes, operand classes and
path classes — never raw arguments; anything secret-shaped is reduced before
storage. The `permissions.precedents` setting selects behaviour and applies
immediately:

| Value | Behaviour |
| --- | --- |
| `off` | No history is read or written. |
| `evidence` (default) | The four closest precedents are added to the judge's evidence as `precedents`. |
| `full` | As `evidence`, plus an exact read-only shape approved twice runs without a model call. |

Precedents are evidence, not grants. They never create command patterns or
directory grants. A precedent informs a judgment only when its permissions
cover the request, so a confined precedent never supports network or
unconfined access. A different program, or a different subcommand when both
name one, never matches. A denial is never overwritten: a signature with both
an approval and a denial is `conflicted` and always asks.

The fast path requires all of: the exact signature, `{execution}` as the only
required permission, `complete` coverage with every assessed access a read, no
denial for the shape, two prior approvals, and a record younger than 90 days.
Such a run reports `allowed by precedent` instead of `allowed by classifier`.
Records are capped at 512 per workspace, least recently seen evicted.

The judge implementation lives in `classification/permissions.dart`, separate
from display-only utterance classification. The app supplies an independent
provider instance for the selected model. Reviews count toward the session's
token ledger and limits. The request includes the full tool input, workspace,
and operation being approved; no tools are available to the judge.

Only a completed, schema-valid `ALLOW` verdict authorizes execution, once.
The schema requires `decision` (an ALLOW/DENY enum), `reason` (a string),
`accesses`, `coverage` and `unresolved`. Each access identifies `operation`
(`read`, `create`, `write`, `delete` or `move`), `path`, and `target_kind`
(`file`, `directory` or `unknown`). Coverage is `complete`, `partial` or
`unknown`; unresolved entries describe effects the model cannot identify.
Legacy two-field verdicts remain accepted with unknown access coverage.
ALLOW can use an empty reason. DENY includes a short explanation of the risk
or uncertainty. The classifier validates it locally too. Prose, Markdown,
extra fields, tool calls and partial
responses never grant permission. Provider adapters request native constraints:
[OpenAI strict JSON Schema](https://developers.openai.com/api/docs/guides/structured-outputs),
[Anthropic output_config.format](https://platform.claude.com/docs/en/build-with-claude/structured-outputs),
and [Gemini responseFormat](https://ai.google.dev/gemini-api/docs/generate-content/structured-output).
[Z.ai](https://docs.z.ai/guides/capabilities/struct-output) documents JSON mode
only: GLM requests constrain JSON syntax and include the schema in the prompt,
with the same local validation. This does not guarantee schema compliance at
generation time. An endpoint rejecting constraints falls back to human approval;
it is never silently retried as an unconstrained text request.
The judge retries a completed malformed verdict once with a stricter prompt;
both attempts share the same 30-second timeout and cancellation signal.
DENY, missing configuration, timeout or malformed output asks the human through
the ordinary approval service. Classifier approval creates no remembered grant.
The fallback names the classifier model and shows its denial reason at the top
of the approval's preview, including on short terminals. Tab shows the complete
permission reason. Other channels receive `auto_approval_denial_reason` in the
approval details. Missing/blank denial reasons are invalid verdicts and fall back
to human review. Tab details show attempt count, answer
and reasoning character counts, and completion status without storing raw output.
Cancellation, shutdown or switching to read-only prevents a late ALLOW from
executing. Changing mode re-evaluates the pending request through the same policy table. The judge stream is cancelled and its provider closed on completion.

Accesses inferred by the classifier are descriptive and never certify a command
or create remembered grants. Tools attach verified accesses independently, so
those details remain visible on timeout or provider failure. Exact file-tool
reports describe the requested effect and exclude atomic-edit cleanup details.
The approval view labels inferred accesses, displays coverage and unresolved
effects, and can offer validated directories for an explicit human grant.
The tools plugin resolves paths against the command's working directory,
canonicalizes symlinks and excludes protected paths and ambiguous targets.
Directory controls appear inside Remember; the `s` key cycles Session, Workspace
and Global. A selected read grant exposes the directory read-only and never
authorizes command execution, network access or mutations. Write grants include
create, rename and delete under the existing write capability.

Network is a permission on the command invocation. Execution and network are
reviewed together, including in auto mode; tools own their separate session
grants. Auto ALLOW never becomes Always. `request(kind: confirmation)` always
uses human Yes/No approval. `humanOnly: true` can instead require a human for
a permission while retaining Allow once / Deny / Remember; the two flags are
independent. An approval cached within one tool invocation cannot authorize a
different permission set or substitute for a confirmation.

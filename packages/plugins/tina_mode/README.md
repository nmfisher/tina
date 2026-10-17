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

| Mode | Reads | Writes inside project | Commands and outside writes |
| --- | --- | --- | --- |
| ask | allow | human approval | human approval |
| read-only | allow | human approval | human approval |
| allow-edits | allow | allow | human approval |
| auto | allow | safety judge | safety judge |

The tools package enforces these decisions on canonical filesystem paths and
process requests. Protected Tina paths and OS confinement cannot be bypassed
by changing mode. Explicit human session grants skip repeat approvals in every
mode. Sub-agents inherit the mode and approval services at creation;
their mode plugin has its own cancellation lifecycle and retains OS confinement.

Read-only and allow-edits automatically allow verified system reader commands
and supported literal reader pipelines/sequences. Other commands still follow
the table above. Network and outside-sandbox requests require separate approval.

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
executing. Changing to another mode reverts to human approval for that pending
request. The judge stream is cancelled and its provider closed on completion.

Accesses inferred by the classifier are descriptive and never certify a command
or create remembered grants. Tools attach verified accesses independently, so
those details remain visible on timeout or provider failure. Exact file-tool
reports describe the requested effect and exclude atomic-edit cleanup details.
The approval view labels inferred accesses, displays coverage and unresolved
effects, and can offer validated directories for an explicit human grant.
The tools plugin resolves paths against the command's working directory,
canonicalizes symlinks and excludes protected paths and ambiguous targets.
Directory grants default to Workspace; the `s` key cycles Session, Workspace
and Global. A selected read grant exposes the directory read-only and never
authorizes command execution, network access or mutations. Write grants include
create, rename and delete under the existing write capability.

Read-only asks before commands that cannot be certified as system readers.
Approving a call does not change the selected mode.

Network is a permission on the command invocation. Execution and network are
reviewed together, including in auto mode; tools own their separate session
grants. Auto ALLOW never becomes Always. `request(kind: confirmation)` always
uses human Yes/No approval. `humanOnly: true` can instead require a human for
a permission while retaining Allow once / Deny / Always; the two flags are
independent. An approval cached within one tool invocation cannot authorize a
different permission set or substitute for a confirmation.

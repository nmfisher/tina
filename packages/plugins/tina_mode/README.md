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

The judge implementation lives in `classification/permissions.dart`, separate
from display-only utterance classification. The app supplies an independent
provider instance for the selected model. Reviews count toward the session's
token ledger and limits. The request includes the full tool input, workspace,
and operation being approved; no tools are available to the judge.

Only a completed, schema-valid `ALLOW` verdict authorizes execution, once.
The schema requires `decision` (an ALLOW/DENY enum) and `reason` (a string);
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

Read-only asks before commands that cannot be certified as system readers.
Approving a call does not change the selected mode.

Network is a permission on the command invocation. Execution and network are
reviewed together, including in auto mode; tools own their separate session
grants. Auto ALLOW never becomes Always. `request(kind: confirmation)` always
uses human Yes/No approval. `humanOnly: true` can instead require a human for
a permission while retaining Allow once / Deny / Always; the two flags are
independent. An approval cached within one tool invocation cannot authorize a
different permission set or substitute for a confirmation.

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

The judge implementation lives in `classification/permissions.dart`, separate
from display-only utterance classification. The app supplies an independent
provider instance for the selected model. Reviews count toward the session's
token ledger and limits. The request includes the full tool input, workspace,
and operation being approved; no tools are available to the judge.

Only an exact ALLOW in a completed response authorizes execution, once.
DENY, missing configuration, timeout or malformed output asks the human through
the ordinary approval service. Classifier approval creates no remembered grant.
Cancellation, shutdown or switching to read-only prevents a late ALLOW from
executing. Changing to another mode reverts to human approval for that pending
request. The judge stream is cancelled and its provider closed on completion.

Read-only asks before every unapproved command, including read-only commands.
Approving a call does not change the selected mode.

Network is a permission on the command invocation. Execution and network are
reviewed together, including in auto mode; tools own their separate session
grants. Auto ALLOW never becomes Always. `request(kind: confirmation)` always
uses human Yes/No approval. `humanOnly: true` can instead require a human for
a permission while retaining Allow once / Deny / Always; the two flags are
independent. An approval cached within one tool invocation cannot authorize a
different permission set or substitute for a confirmation.

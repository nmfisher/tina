# tina_mode

Grants are independent of approval mode. The selectable modes are `approve`
(human review) and `auto` (model review of ungranted external access).
Workspace reads are allowed. The first workspace write requires human approval
for workspace-wide writes for the session, shared with child policies.
Switching modes changes the reviewer and preserves existing grants.

Auto review approves when the action accesses no secrets and deletes no files
outside the workspace. Violations deny the request; uncertainty or an unavailable
judge goes to the human. Auto approvals apply once and create no standing grants.
Approval precedents never waive review.

`/mode` and Shift-Tab select `approve` or `auto`. Old saved names migrate to
`approve` without granting writes. `--yolo` remains a launch-only override.
Confirmation requests and unconfined execution remain human-only.

See [resource permissions](../../../docs/permissions.md) for saved path grants,
command enforcement, migration, and limitations.

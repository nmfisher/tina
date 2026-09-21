# Edit preparation and conflicts

The standard `edit` tool checks its exact match before requesting approval.
Invalid arguments, missing matches, and ambiguous matches return to the agent
without prompting the user, writing a file, or creating a backup. Permission
denials and exploration-stage restrictions are checked before preparation.

`EditRequest` and `prepareEdit` hold the shared validation and matching logic.
`EditTool.prepare` reads through the configured filesystem and sandbox, then
returns a `PreparedEdit` snapshot. The normal and workflow approval previews
use that snapshot. A preview without a prepared snapshot explicitly labels
itself as an unchecked proposal.

After approval, the tool takes its per-file mutation lock and compares the
current text with the prepared snapshot. Any text change returns a conflict,
even if `oldString` still matches. This prevents silently applying a proposal
to a different file version or expanding an approved `replaceAll` operation.
The lock is not held while waiting for approval. Direct tool callers continue
to prepare and apply within one locked read/modify/write operation.

An `EditConflict` includes a JSON result with `code: edit_conflict`, a reason,
match count, bounded current context with line numbers, line-ending information,
and recovery instructions. `replacementTextPresent` is only a hint: finding the
replacement somewhere does not establish that the intended change is complete.
The agent should inspect the current file, verify whether work remains, and
submit a corrected exact edit if necessary. No fuzzy replacement, automatic
success, or automatic replay follows from a conflict.

The existing permission policy applies to corrected edits. The filesystem lock
coordinates Tina's file tools; it does not lock out external editors. Snapshot
revalidation detects changes observed before application, while the existing
atomic-write path protects against partial file writes.

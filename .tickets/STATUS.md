# Sweep status
Now:     Reworded the approval-surface review (tin-3i3l) into plain
         technical English — same findings, same recommendations, same
         file:line anchors; no analysis changed. The proposal stands:
         inventoried all 13 human-decision points; the seam is real
         (PermissionAsker typedef, prompt.dart:306) but the wiring is
         not — every interactive asker is built inside TuiCoordinator,
         and no open ask survives a restart. Daemon: right goal, not a
         current requirement; six ordered steps land most of it first:
         fix who-denied records → durable AskStore → /approve, /deny,
         /answer commands → answerability-in-posture → fail-closed
         unattended gates → tina serve. Fail-open finds stand:
         HeadlessInterviewer auto-yes, ask_user null-asker
         auto-first-option, AskUserTool(null) at
         orchestrator_tools.dart:29; decidedBy defaults 'user'
         (prompt.dart:290) so the scheduler auto-deny and
         workflow/conversation fallbacks misattribute to the user.
Next:    Owner call on ordering: tin-3i3l steps 1–3 (provenance,
         AskStore, answer commands) are standalone and unblock remote
         answering; steps 4–5 fold into plugin_posture_door.md
         (answerability and fail-closed gates are posture concerns).
         Then the carried-over queue: tin-p4wm item 3 (`/spawn`+`/branch`
         drop configured static rules), then tin-w7dr (needs the live
         wheel repro). tin-r6km resumes at proposal P6–P8 + the PR #49
         review fixes (P0–P5 review items 1–3 and 5–7 remain open on
         main).
Blocked: tin-r6km P8 is blocked on the review fixes; nothing else.
Ask:     tin-p4wm item 2 needs a posture decision: declaring
         `explore_project` a project read flips its default ask → allow.
         Also: greenlight tin-3i3l steps 1–3 ahead of / alongside the
         posture door.
Last checkpoint: 2026-09-25 — approval-surface review (tin-3i3l);
         proposal reworded for clarity; ticket + STATUS kept in sync.
         Previous (2026-09-25): approval-surface review filed;
         post-#61 docs refresh (tin-n8vq).

# Sweep status
Now:     Second external review of fa2d20f applied: the revised
         architecture stands; three residual passages that still taught
         the superseded design are fixed. (1) "The turn must end while
         a question is open" was itself wrong — the executor holds the
         turn in flight across the ask (host_interface.dart:74-78) and
         a pending Future blocks nothing; ending the turn is a host's
         choice, the real requirement is reachable approval +
         cancellation ingress. (2) The audit still said a remote host
         "needs the durable ask store first" and implied "a process
         alive per open question"; both now split live remote operation
         (in-memory, no store) from restart recovery (durability). (3)
         The answer route no longer collapses every ask into
         PermissionResponse: dispatch is by ask kind — permission →
         PermissionResponse, questions → Answer values, plan →
         PlanStore — and ask_user is described as what it is, a batch
         callback returning List<Answer> (ask_user_tool.dart:15), not
         an Interviewer consumer. Anchors re-validated 157/157.
Previous: External design review of the two proposals (tin-3i3l +
         tin-7b7k) incorporated; central findings confirmed, four
         claims corrected with the code checked each time:
         (1) parking an ask does NOT resume execution — a denial
         completes the tool result (tool_executor.dart:620-649);
         suspension/resume is separate future work; (2) build deps
         code_assets/hooks/native_toolchain_c must STAY in
         dependencies while hook/build.dart is in the engine (consumers
         execute the hook; dev deps are ignored downstream) — only
         extracting PTY+hook+deps removes them; (3) not one ask seam:
         PermissionAsker (permission asks) + Interviewer
         Question/Answer (ask_user, workflow gates) + PlanStore
         requested (plans) — "no protocol invention" and "mostly glue"
         reworded to one adapter per seam + transport work; (4) split
         presentation from authorization in "what stays terminal-only"
         — the decision must stay remote-answerable or the motivating
         case is dead. Ordering relaxed: provenance + unattended
         defaults → narrow remote host on the existing async interfaces
         (a pending Future blocks nothing; durability is separate) →
         durable records → suspension/resume if still needed. Both
         documents carry a "Corrections after external review" section.
Next:    Owner call on ordering: tin-3i3l steps 1 and 5 (provenance,
         fail-closed defaults) are standalone; the review's step 3 (a
         narrow remote host on existing async interfaces) proves the
         contracts before the AskStore lands; PTY packaging stays a
         separate cleanup. Then the carried-over queue: tin-p4wm item 3
         (`/spawn`+`/branch` drop configured static rules), then
         tin-w7dr (needs the live wheel repro). tin-r6km resumes at
         proposal P6–P8 + the PR #49 review fixes (P0–P5 review items
         1–3 and 5–7 remain open on main).
Blocked: tin-r6km P8 is blocked on the review fixes; nothing else.
Ask:     tin-p4wm item 2 needs a posture decision: declaring
         `explore_project` a project read flips its default ask → allow.
Last checkpoint: 2026-09-26 — second review pass (fa2d20f) applied
         (turn-wait choice, live-vs-recovery split, per-kind answer
         dispatch). Previous (2026-09-26): external review of
         tin-3i3l/tin-7b7k incorporated (four corrections + ordering;
         correction logs in both documents). Earlier (2026-09-26):
         interface decoupling audit (tin-7b7k) filed; ticket + STATUS
         updated. Earlier still (2026-09-25): approval-surface review
         reworded (tin-3i3l).

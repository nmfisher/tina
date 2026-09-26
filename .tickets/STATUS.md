# Sweep status
Now:     External design review of the two proposals (tin-3i3l +
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
Last checkpoint: 2026-09-26 — external review of tin-3i3l/tin-7b7k
         incorporated (four corrections + ordering; correction logs in
         both documents). Previous (2026-09-26): interface decoupling
         audit (tin-7b7k) filed; ticket + STATUS updated. Earlier
         (2026-09-25): approval-surface review reworded (tin-3i3l).

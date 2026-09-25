# Sweep status
Now:     Docs refresh after PR #61 landed (tin-n8vq, closed): the approvals
         docs (plan_approval.md, ARCHITECTURE.md, plugin_architecture.md
         §11) re-anchored to main @ 2118b35 and rewritten to document the
         plugin-owned posture read as current behaviour; new proposal
         docs/proposals/plugin_posture_door.md (core-minted PlanPosture,
         grant provenance, then a scope-key door). Structural gaps stay
         open: the door itself, posture duplication
         (plan_plugin.dart:146-147 vs policy.dart:250), the three deny
         dialects vs the plan gate's fail-open auto-grant, and PlanGrantSource.
Next:    Greenlight plugin_posture_door.md (owner call; steps 1–3 are
         mechanical, step 4 waits for a second posture consumer), then the
         carried-over queue: tin-p4wm item 3 (`/spawn`+`/branch` drop
         configured static rules — smallest, crisp acceptance test), then
         tin-w7dr (needs the live wheel repro first). tin-r6km resumes at
         proposal P6–P8 + the PR #49 review fixes (P0–P5 review items 1–3
         and 5–7 remain open on main).
Blocked: tin-r6km P8 is blocked on the review fixes; nothing else.
Ask:     tin-p4wm item 2 needs a posture decision: declaring
         `explore_project` a project read flips its default ask → allow.
Last checkpoint: 2026-09-25 — post-#61 docs refresh (tin-n8vq); STATUS.md
         rewritten. Previous (2026-09-25): approvals docs pass (tin-4m0q).

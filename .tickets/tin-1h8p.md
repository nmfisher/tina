---
id: tin-1h8p
status: done
deps: []
links: []
created: 2026-08-08T04:29:06Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [permissions, classifier, auto-mode, feature]
---
# Auto-mode: classifier decides tool approvals when the rule engine says ask

Add an optional classifier-based auto-approval mode for tool permissions. Today PermissionPolicy.check in packages/tina_engine/lib/src/permissions/policy.dart is a deterministic cascade: session rules, static rules (--allow patterns), builtin defaults (read allow; write, edit, bash ask), then ask fallback. No model judgment. The design: insert a classifier step between the rule cascade and the ask fallback. When the cascade yields ask, call a small model on the tool call (tool name, input, plus context such as recent commands or project state) and let it return allow or deny, with the user prompt as the backstop. Precedence must stay: yolo skips everything, safe-mode dominates yolo, explicit rules beat the classifier, the classifier only fires on an ask verdict. Decisions should be visible in the UI and remembered like manual ones. Opt-in via config. Non-interactive auto-approve today stays or is superseded by this. Tests with a fake classifier.

## Acceptance Criteria

When enabled, an ask verdict routes to the classifier instead of the user; classifier allow and deny both work; explicit rules and yolo and safe-mode keep their precedence; classifier decisions are visible and remembered; disabled by default; tests pass.


# Permission rules

This page covers **tool approval** — the per-call "may I run this?" gate in
the engine's permission layer. It is one of two approval mechanisms: plan
approval ("do you approve this plan of work?") is a separate, plugin-owned
mechanism that no permission rule or flag can reach — see
[Plan approval](plan_approval.md) for the contrast.

Escape dismisses a pending tool approval and cancels the current turn. The
draft is preserved; the model is not called again until you submit a message.
Choosing **deny once** explicitly sends a denial and lets the agent continue.

Use `--allow TOOL:PATTERN` and `--deny TOOL:PATTERN` for existing wildcard rules.
Use `--allow-regex TOOL:REGEX` and `--deny-regex TOOL:REGEX` for regular expressions:

```sh
tina --allow-regex 'bash:git (status|diff)( --stat)?'
tina --allow-regex 'read:/workspace/(src|test)/.*\.dart'
tina --deny-regex 'bash:git (push|reset).*'
```

Regex rules use Dart regular expressions, are case sensitive, and must match the
**entire approval target**. Anchors are optional. `bash:git (status|diff)` matches
`git status` and `git diff`, but not `git status; git push`. Use `.*` explicitly
where arbitrary text is intended. Matching examines the target string; it does
not parse shell syntax or classify a command's effects.

Each option can be repeated. Quote expressions to keep your shell from expanding
them. Commas inside regexes, including quantifiers such as `{1,3}`, are preserved.
Invalid regexes fail at startup. Configured deny rules precede configured allow
rules, across both wildcard and regex forms. Existing session-grant precedence
and permission-mode restrictions still apply.

The target is the same string shown for approval: a command for ordinary `bash`,
a path for file tools, or a URL for `fetch`. `exec` and `bash` with an explicit
environment use a serialized invocation including the working directory and
environment. Regex rules do not grant outside-sandbox execution; those approvals
continue to match exact prepared invocations separately.

`/permissions` labels regex rules with `(regex)`. Saved configured rules retain
their match type on session restore; records without a type keep wildcard
semantics. The approval list's “always” choices continue to generate their
existing rules automatically.

Ordinary tool approvals also offer **rewrite to safe regular expression** (`r`).
This opens an inline editor seeded with a model-drafted pattern: the approval's
tool name and exact target are sent to the classifier model (the `[permissions]
model`), which is asked for a conservative generalization — enumerate the safe
alternatives rather than reach for wildcards, and never allow anything the
target itself does not. Every draft is validated locally before it is shown: it
must be a valid expression, match the entire current target, and contain no raw
control characters. The editor paints the literal escaped target immediately,
and the draft replaces it only if you have not typed yet; a late or failed draft
(timeout, provider error, unusable answer) keeps the escape and says why. With
no classifier provider configured, the rewrite offers only the literal escape,
as before. Edit the expression, press Enter
to review it, then choose **Allow and save for this conversation** to confirm.
Invalid expressions and rules that do not match the current target cannot be
confirmed. The command itself remains unchanged — and so does the model's
suggestion: it is a starting point for you to judge, never an automatic grant.

The reviewed rule lasts until the conversation ends or Tina exits, appears in
`/permissions`, and can be removed with `/permissions revoke TOOL:PATTERN`.
Esc returns to editing or the approval list; Ctrl+C or double-Esc cancels without
saving. The editor preserves the conversation draft. Directory-access and
outside-sandbox approvals keep their separate, exact grant mechanisms.

Plugins and application code can construct a rule with
`PermissionRule.regex(toolName: 'bash', pattern: r'git (status|diff)',
decision: PermissionDecision.allow)`. The existing const `PermissionRule`
constructor remains a wildcard rule.

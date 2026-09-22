# Permission rules

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
This opens an inline editor with an escaped regex matching exactly the current
target. Suggestions are generated locally and immediately; they do not ask a
model to infer which other commands are safe. Edit the expression, press Enter
to review it, then choose **Allow and save for this conversation** to confirm.
Invalid expressions and rules that do not match the current target cannot be
confirmed. The command itself remains unchanged.

The reviewed rule lasts until the conversation ends or Tina exits, appears in
`/permissions`, and can be removed with `/permissions revoke TOOL:PATTERN`.
Esc returns to editing or the approval list; Ctrl+C or double-Esc cancels without
saving. The editor preserves the conversation draft. Directory-access and
outside-sandbox approvals keep their separate, exact grant mechanisms.

Plugins and application code can construct a rule with
`PermissionRule.regex(toolName: 'bash', pattern: r'git (status|diff)',
decision: PermissionDecision.allow)`. The existing const `PermissionRule`
constructor remains a wildcard rule.

---
id: tin-6a2f
status: closed
deps: []
links: [tin-c5nw]
created: 2026-08-15T15:10:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, approvals, rendering, prompt-overlay]
---
# Approval prompt: a second approval's text renders merged onto the first approval's prompt line

## Context

When two permission prompts arrive in quick succession (a denied/answered
approval immediately followed by the agent's next tool call), the second
approval's command header ("  bash: ...") renders on the SAME screen line as
the first approval's trailing prompt ("approve? ... › "), producing a merged
garbled line like:

```
  approve? [y/n/a/d]  (a/d remember "pwd; ls -la") ›   bash: ls -la /workspace/examples/workspace/ 2>/dev/null | head -50; echo "---"; find ...
```

The second prompt's "approve? ... ›" input line follows on the next row, so the
approval still works, but the transcript line is corrupted and the first
approval's answer character is never shown.

## Repro

1. Start tina in a detached tmux pane (reply injection per tin-r2vd) in a repo
   without an environment record (first-load ceremony: the environment agent
   issues rapid consecutive bash commands, each gated).
2. Let several approvals cycle (answering y/a each time).
3. Observed: at least one row shows the previous approval's "approve? ... ›"
   text immediately followed by the next tool call's header on the same line.
   Seen reliably during the environment-agent first-load ceremony (2026-08-15,
   sweep run T11 at 120x40).

## Notes

Same approval-prompt area as tin-c5nw (Ctrl+G leaking into approvals). The
approval is written as plain chat lines (lib/host/tui_conversation_host.dart
askPermission: chat.write of the prompt + the answer char) — the second
approval's chat.yellow("  bash: ...\n") lands on the same row as the first
approval's incomplete prompt line, i.e. the chat row cursor did not advance
between the two prompts.

## Acceptance

- Two approvals in quick succession render on separate, uncorrupted lines.
- Regression test with a fake chat region asserting row advance between
  consecutive askPermission prompts.

## Resolution (2026-08-16)

Root cause: an approval prompt is an intentionally partial row —
askPermission writes "approve? … › " and the answer character joins the
same line after readKey. While that row was open, a background writer (the
environment ceremony streaming into the same chat) appended its text to the
prompt row, so the next tool call's header merged onto the prompt line and
the answer char was hidden.

Fix (fc43037): the prompt+answer pair carries a row-ownership token; the
region tracks the owner of the currently-open partial row and any OTHER
writer's text advances to a fresh row instead of appending. Unowned
streaming chunks still join each other unchanged.

Reproduced live at 80x24 (T9 with a first-load ceremony): the second
approval's header spliced onto the first approval's prompt row pre-fix;
post-fix the rows are clean and the answer char renders. Regression:
approval_row_ownership_test.dart. Suites: root +538, tina_console +676.

---
id: tin-g2w9
status: closed
deps: []
links: [tin-9zqx, tin-k7tr]
created: 2026-08-17T05:58:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [persistence, data-loss, resume, jsonl]
---
# Session store glues new records onto a torn JSONL tail — silent message loss

## Context

The per-conversation JSONL is append-only. If a process dies mid-append
(kill -9, power loss — the brief's "kill -9 mid-write, then restart" seed),
the file's last line is a torn, unterminated JSON record. The loader
correctly detects and skips it (WARNING "skipped corrupt line N" in
`~/.tina/tina.log`). But the writer never repairs the tail: the next
append writes `record + '\n'` at EOF, gluing the new record onto the torn
line with no separating newline.

Consequences, all verified live (stub provider, fresh HOME):

1. The glued line is unparseable, so on the **next** load BOTH records are
   dropped: the torn assistant turn *and* the first user message sent
   after the crash. Silent data loss — the app reports
   `session saved: 3 messages` while a reload yields 2 records.
2. A clean `/exit` does not rewrite the file from memory, so the glue is
   permanent; every subsequent load re-warns on the same line.

## Repro (deterministic, stub)

1. Fresh `HOME` with the stub provider config; run one turn in tina, `/exit`
   → `~/.tina/sessions/<id>/<conv>.jsonl` has 2 valid lines.
2. `truncate -s $((size-120))` the JSONL — last line now torn mid-string,
   no trailing newline (identical shape to a crash mid-append).
3. `tina --resume <id>` — loader logs `skipped corrupt line 2`
   (FormatException: Unterminated string).
4. Type any message, Enter.
5. Inspect the file: line 2 is now
   `{"role":"assistant",…never i{"role":"user","content":…}` — the new
   user record glued onto the torn tail.
6. `/exit`, `--resume` again → `skipped corrupt line 2`
   (FormatException: Unexpected character at 225); the user message sent
   in step 4 is gone from the conversation.

## Fix direction

The append path (or the load path, before the store is marked writable)
must ensure the file ends with `\n` before appending — e.g. on open for
append, if the last byte is not `\n`, truncate to just past the last valid
newline. The loader already knows the corrupt tail's offset; either side
works, but the append-side guard protects against every writer, not just
post-restore ones.

## Acceptance

- Unit test: JSONL with a torn last line + an append → the append lands on
  its own line; a re-load parses every line including the appended record.
- The live repro above: after resume + one message + restart, the message
  is present (only the torn fragment itself is dropped, which is
  unavoidable).
- Root suite + `packages/tina_engine` suite green.

## Resolution (2026-08-17)

Fixed in `JsonlSessionStore.append`
(packages/tina_engine/lib/src/persistence/jsonl_session_store.dart):
appends now go through one `RandomAccessFile` handle that first repairs an
unterminated tail — a tail that parses as a complete record (crash between
record and newline) gets its newline; a torn tail is truncated back to the
last newline with a WARNING. Note the trap found on the way: Dart's
`FileMode.append` for `RandomAccessFile` only *seeks* to EOF at open — it
does not force writes there — so the handle is explicitly re-positioned
after any truncate.

- Regression tests: 'append after a torn final record does not glue onto
  it' + 'append keeps a complete final record that only lacks its newline'
  (jsonl_session_store_test.dart).
- Root suite 540/540. tina_engine package suite at its clean-tree baseline
  (one pre-existing process_tree failure, sandbox-related, identical with
  the fix stashed).
- Live repro re-run from a clean restart on the fixed build: WARNING
  `dropped torn final record (262 bytes) … before append`; the message
  sent after the "crash" persisted on its own line and survived the next
  reload.

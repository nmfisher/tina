# SP3 — Provider selection config

Status: proposed.
Prerequisites: SP1; benefits from SP2.
Index: [README.md](README.md).

## Problem

Once multiple backends can exist (SP1's mechanism, SP5's example), users need
a way to pick one. Today the backend is implicit: whoever constructs the
store. Selection must happen before the runtime activates (SP2's startup
reads) and again when the plugin list is composed.

## Implementation

```toml
[sessions]
provider = "jsonl"        # default; must match a registered backend id suffix

[sessions.jsonl]
# root = "/custom/path"   # optional; defaults to today's location
```

Wired through the existing `RuntimeConfig` (decoded where other config blocks
are). Two consumers:

1. **`resolveSessionIndex(RuntimeConfig)`** (from SP2): reads `[sessions]`,
   returns the selected backend's index. Until SP5, only `jsonl` exists, so
   this is the default.
2. **Composition root**: when building the plugin list, include the plugin
   whose id matches `tina.engine.session-store-<provider>`. Until SP5, the
   list contains only the jsonl plugin; the config id is validated against it.

Unknown `provider` id: **fail fast at startup** with the offending id named,
before any session is created — never mid-session. This is the program's one
error-handling rule and it lives here.

### Config plumbing notes

- `RuntimeConfig` decoding lives where other config blocks are decoded
  (`lib/config/` at the root); keep `[sessions]` in the same family — do not
  invent a parallel decoder.
- No generic `[plugins.*]` config surface exists yet. When
  `plugin_runtime.md`'s program lands one, `[sessions]` remains the selection
  surface and `[plugins.<id>]` the per-plugin config — matching the split the
  runtime plan already describes (`PluginConfigDecoder` per descriptor).
- On conflict, selection (`[sessions] provider`) wins over per-plugin config;
  ambiguity resolves to the fail-fast error.

## Migration

1. Add the `[sessions]` table to `RuntimeConfig` (optional, absent ⇒ jsonl
   default, identical behavior).
2. `resolveSessionIndex` reads it; composition validates the id when
   composing the plugin list.
3. Unknown id fails at startup with the id named.

## Validation

- Absent config ⇒ identical behavior and paths (default jsonl).
- `provider = "jsonl"` explicit ⇒ same as absent.
- `provider = "nonexistent"` ⇒ startup failure naming `nonexistent`, before
  any session creation.
- `resolveSessionIndex` and the composed plugin list agree (same id read once,
  validated once).

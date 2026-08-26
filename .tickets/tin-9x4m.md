---
id: tin-9x4m
status: done
deps: []
links: []
created: 2026-08-18T00:00:00Z
type: bug
priority: 3
assignee: Nick Fisher
tags: [tui, spawn, providers, config]
---
# /spawn model picker is empty for custom (user-defined) providers

## Context

Found during the tin-y4qn live hunt: with a config whose only provider is a
user-defined id (e.g. `[providers.stub]` with `base_url` at a local stub),
`/spawn` opens the model picker showing `(no items available)`.

`runSpawnOverlay` (lib/tui/spawn_overlay.dart) builds entries from
`registry.modelsFor(id)` for each configured provider — but a user-defined
provider has no model catalog, so the list is empty. The panel title in that
config also renders as `main (stub-1)` (model ref with no provider prefix
split), so custom-provider configs clearly are meant to work end-to-end.

## Repro

1. `~/.tina/config` with only a custom provider id (any base_url) and
   `[default] provider = "<custom>"`.
2. Start tina, type `/spawn`, Enter.
3. Picker shows `Spawn agent — (no items available)`.

Worse than cosmetic: the overlay stays open and consumes keys (Enter is a
no-op on an empty list), so typed input silently goes nowhere until Esc —
the hunt's keystrokes were swallowed for several seconds before this was
understood.

## Scope / notes for the fix

- Either let user-config declare a models list (config schema +
  `ProviderConfig`), or seed the picker with a synthetic
  `<provider>/<default-model>` entry for custom providers.
- Consider whether an empty picker should fall through / show a hint instead
  of consuming Enter.

Workaround (used by tool/y4qn_hunt.sh): configure a built-in provider id
(e.g. `deepseek`) and override its `base_url` to the stub — built-ins carry
a catalog, so the picker lists models.

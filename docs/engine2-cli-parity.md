# CLI migration audit (v0.9.2)

Compared the legacy argument parser in `lib/config.dart` with the active parser
in `packages/tina_tui/lib/src/cli.dart`. Missing flags below are not a request
to port the legacy command surface or enable deferred features.

## Session entry points restored

- `tina --continue` / `tina -c`: resume the most recently updated main session
  in the current workspace's `.tina/sessions.db` (or `--store FILE`).
- `tina --resume`: print main sessions, newest activity first, and select by
  number. Enter, `q` or EOF cancels without starting the app. Invalid numbers
  prompt again. This also accepts a selection from piped input.
- `tina --resume ID` / `tina --resume=ID`: resume a known ID directly.
- Missing or empty history reports an error (exit 66), without creating a new
  session. Child sessions are omitted from the picker and continue lookup;
  an explicit ID can still reopen one. Activity means the last locally stored
  entry or metadata write, including import order for imported conversations.
- `--sessions` is removed. Legacy `--list` / `-l` is not restored.

The store closes before the picker or app starts. `--continue`, `--resume`,
`--configure` and `--import-sessions` are mutually exclusive. Persistence must
be enabled to resume. Old on-disk sessions still need `--import-sessions` first.

## Other differences still outstanding

| Legacy entry point / behavior | Current engine2 behavior |
| --- | --- |
| `--model`, `--models [provider]` | Restored, alongside the plugin-owned `/model` picker. |
| Resume restores the saved model unless overridden | Restored for sessions with model metadata; older rows fall back to the configured model. |
| `--prompt` | Restored for headless runs; `--prompt -` reads stdin. Approval requests are denied without a human channel. |
| `--base-url`, `--max-output-tokens` / `--max-tokens`, `--reasoning-effort` | No corresponding CLI overrides. Provider/generation configuration is supported; see the config audit. |
| Token, sub-agent and request-rate limit flags | Config supports these settings, but their legacy CLI overrides are absent. |
| `--max-steps`, `--auto-compact-threshold` | No CLI overrides. Step-policy extraction remains a separate proposal, not part of this release. |
| `--watchdog-seconds`, `--stream-idle-timeout`, `--request-timeout`, `--transport-retry-attempts` | No equivalent CLI controls; current provider retry behavior is documented separately. |
| `--allow`, `--deny`, regex variants, `--yolo`, `--permission-mode`, `--safe-mode`, sandbox flags | No legacy launch flags. Current tool approval/mode/sandbox behavior is separate; do not assume legacy launch policies are applied. |
| `--trust` / `--no-trust`, `--force` | No CLI overrides for the legacy project-trust or session-lock behavior. This flag audit does not establish equivalent runtime policy. |
| `--verbose` / `-v` | Verbose flag absent; **`-v` now prints version**, unlike the legacy CLI. |
| `--init-config`, `--setup` | Replaced by first-run settings and `--configure`; no template-only `--init-config` mode. |
| `--layout`, `--backend` | No launch flags; current panel/rendering behavior is controlled by the TUI. |
| `--workflow`, `--enable-workflow` | Intentionally deferred; do not reconnect workflows/Attractor. |

Model override/listing, session model restoration and headless prompts are implemented. Decide the
verbose shorthand and permission/trust semantics explicitly rather than
silently copying the old flags. Repository indexing remains deferred; the
classification plugin is display-only.

See [configuration compatibility](engine2-config-audit.md),
[current configuration](engine2-config.md),
[legacy session import](engine2-session-import.md), and the
[policy/plugin handoff](proposals/engine2-policy-plugin-handoff.md).

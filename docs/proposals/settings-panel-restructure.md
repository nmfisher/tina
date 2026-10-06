# Settings panel: scoped-only restructure

Status: proposed. User direction: clean break — legacy compatibility and the
dual-mode panel are explicitly disposable. This plan supersedes the small
"hide the scope row at the root" fix; that fix falls out of commit 3 below.

## Goal

One settings panel with one mode (scoped settings), scope selection owned by
the leaf editors that apply it, and a file split so no module carries all of
navigation + editing + chrome. Delete the legacy ConfigDocument editing path
from the panel and route first-run `tina config` through the same scoped stack
as `/settings`.

## The smells being removed

All references are `packages/tina_tui/lib/src/settings_panel.dart` unless
noted. The file is 1807 lines.

1. **Two panels in one class.** `run()` (line 167) builds the legacy
   ConfigDocument entry list; `_scopedRun()` (line 287) builds a parallel
   scoped entry list describing the same catalog. `_ownerCategory` (423) and
   `_sectionTitle` (515) exist to translate scoped owner IDs into the legacy
   path's hardcoded category labels. `_usingScopes` (41) and the
   `Scope: [global]` fallback in `_scopeLine` (55–61) exist only for the
   legacy mode.
2. **Scope is a mutable global.** `_scope`/`_availableScopes` are panel
   fields; `_menu` — a generic list widget — mutates them on Tab (1624–1627).
   `_withinScopes` (68–77) is save/restore dynamic scoping around a callback.
   Consequences visible today: the root menu must paint a scope line because
   Tab there can change state the root cannot show (the question that started
   this), and `_section` (1135–1145) plus `_allowedScope` (543–553) already
   implement per-setting scope pickers that partly duplicate Tab.
3. **Generic chrome is overloaded.** `_menu` has 15 optional parameters
   (1503–1521) mixing navigation, value editing, and scope switching; its
   footer hardcodes capability text (1554–1558).

Call sites that force the dual mode:

- `app.dart:89` and `session_view.dart:108` — scoped `/settings`.
- `app.dart:536` `runConfigEditor` — legacy-only; used by `cli.dart:253–264`
  for `tina --configure` and first-run when the config file does not exist.

The scoped stack itself is constructed in exactly one place today,
`assembly.dart:258–283` (registry → `createSettingsCatalog` →
`ConfigSettingsBackend` → `ScopedSettings`). `runConfigEditor` not using it is
the only reason the legacy branch survives.

## Target design

### File map (packages/tina_tui/lib/src/)

| File | Contents moved from settings_panel.dart | ~Lines |
|---|---|---|
| `settings_menu_host.dart` | `MenuHost`: screen, `LineEditor`/`readEvent` plumbing (`_nextEvent`, `_pendingRead`, `_changed`, `_refresh`, `repaint`, `cancel`), overlay+cursor lifecycle, `_frame`, `_show`, `_menu`, `_edit`, `_formEvent` | 420 |
| `settings_panel.dart` | `SettingsPanel` shell: `run()` (scoped-only), entry-list construction, `_browseSettings` root/category/search navigation, `_ownerCategory`/`_sectionTitle` (now single-use), error surface in `_openEntry` | 350 |
| `settings_scope_editor.dart` | `ScopeSelection`; `_definitions`, `_scopedValue`, `_editScopedValue`, `_definitionHelp`, `_applyLabel`, `_settingRow`/`_settingValue`, `_allowedScope` logic | 250 |
| `settings_plugins.dart` | `_scopedPlugins` matrix (column navigation, per-scope overrides, `setPluginInAllScopes` flow) | 180 |
| `settings_providers.dart` | Global-only document forms: `_defaultModel`, `_providers`, `_providerFields`, `_generation`, `_preview` | 450 |
| `settings_contributions.dart` | `_section` for `SettingsRegistry` contribution sections (toggle/text/choice/action/`ScopedSettingControl`) | 130 |

`providers_panel.dart` (tina_console) and `ModelSearchPicker`
(tina_console) are untouched; they already take `contextLine` as a parameter.

### ScopeSelection

Replaces the `_scope`/`_availableScopes`/`_usingScopes` fields and
`_withinScopes`:

```dart
final class ScopeSelection {
  ScopeSelection(this.available, [this.current = SettingScope.session]);
  final Set<SettingScope> available;
  SettingScope current;

  void cycle(int delta) { /* wrap within available */ }
  String render() => [
        for (final s in SettingScope.values.where(available.contains))
          s == current ? '[${s.name}]' : s.name
      ].join('  ');
  ScopeSelection restrictedTo(Set<SettingScope> scopes) =>
      ScopeSelection(available.intersection(scopes),
          available.contains(current) ? current : /* lowest allowed */ null);
}
```

Rules:

- Each leaf editor owns a local `ScopeSelection` variable. Root and category
  menus have none: no Tab handler, no scope row. This is the structural fix
  for the original complaint — scope is chosen where its effect is rendered.
- `_menu` loses the `ControlKey.tab when _usingScopes` case (1624–1627)
  entirely. Tab/←→ reach editors only via `onHorizontal`, which leaf editors
  wire to `selection.cycle`. The plugins matrix keeps its existing
  `onHorizontal` column model, now writing its local selection instead of
  `_scope` (685–688).
- `_scopedValue`, `_editScopedValue`, `_definitions` take the selection as a
  parameter and read `selection.current` when calling `settings.set` /
  `removeOverride` / `backend.draft`. `_withinScopes` becomes
  `selection.restrictedTo(definition.scopes)`.
- `_allowedScope` becomes "pick a supported scope": when
  `definition.scopes` excludes `selection.current`, show the existing picker
  menu and write `selection.current` (local, not panel state).
- `_section`'s per-control scope picker (1135–1145) writes the section-local
  selection the same way.
- `contextLine: () => selection.render()` replaces every `() => _scopeLine`.
- The `_show` scope-row fallback (1434–1437) becomes: paint
  `contextLine?.call()` only; no panel-level default. `_compactRow`'s
  `'Scope:'` special case (1467) is deleted along with `_scopeLine`.

### MenuHost

Constructed per panel `run()` (or by tests) with `screen`, optional
`readEvent`, and the input session lifecycle. Owns `_overlay`, `_cursor`,
`_paint`, and exposes `menu`, `edit`, `show`, `formEvent`, `nextEvent`,
`refresh`, `repaint`, `cancel`. Sub-editors take the host plus their data
(`ScopedSettings`, catalog, descriptors). `cancel()` stays the teardown hook
`app.dart`/`session_view.dart` already call paths through.

`_menu`'s footer text is derived from capabilities actually provided
(`onHorizontal` → `←→/Tab column · …`; checkboxes → `space toggle · …`;
plain → `↑↓ move · enter select · esc back`), removing the `_usingScopes`
conditional at 1557–1558.

### First-run / `tina config` on the scoped stack

Extract assembly.dart:258–283 into a shared factory, roughly:

```dart
final class ScopedSettingsStack {
  static (ScopedSettings, ConfigSettingsBackend) build(
      {required String configPath,
      required String workspacePath,
      List<ProviderDescriptor>? descriptors,
      PluginRegistry<TuiPluginContext>? registry}) { ... }
}
```

- `TuiAssembly.start` calls it (no behavior change).
- `runConfigEditor` calls it with `workspacePath: configPath` (the backend's
  `sameFile` canonicalization already collapses that), constructs
  `SettingsPanel`, and runs scoped-only. The `!File(path).existsSync()`
  first-run branch in `cli.dart:253` and `--configure` keep working with no
  legacy code path.

### SettingsPanel after the break

`run()` requires `scopedSettings` and `settingsBackend` (positional or
named-required). Deleted: the unscoped branch of `run()` (154–260), legacy
`_plugins` (940), the legacy raw-table entries (limits at 193–221, theme at
223–234, terminal alerts at 235–253 — scoped equivalents already exist at
364–383), `_usingScopes`, `_scopeLine`, `_scope`, `_availableScopes`,
`_withinScopes`. The `document` opened in `run()` remains in use for the
contribution-sections refresh path (`document.refreshUneditedTables()` +
`_applyConfiguration`, 400–404) and stays.

## Commit ladder

One commit per step; `dart analyze` clean and the touched suites green after
each; full `dart test` before pushing. Move-only commits contain no behavior
change.

1. **Scoped-settings stack factory.** Extract
   `ScopedSettingsStack.build` from `assembly.dart:258–283`; assembly uses it.
   Pure move; all existing tests stay green unchanged.
2. **Clean break: delete the legacy mode.** `run()` becomes scoped-only with
   required params; `runConfigEditor` builds the stack via the factory;
   delete the legacy branch, legacy entries, `_usingScopes`, and the
   `[global]` fallback. Port tests off the unscoped drive (table below).
   Root still shows the scope line and Tab still works everywhere in this
   commit — behavior parity with today's scoped mode, minus the dead mode.
3. **Thread ScopeSelection through leaves.** Introduce
   `settings_scope_editor.dart` with `ScopeSelection`; leaf menus own
   Tab/←→ via `onHorizontal` and paint `selection.render()`; remove the
   `_menu` Tab case and the `_show` scope-row fallback. Root/category menus
   show no scope row and ignore Tab. Update `panels_test.dart:422` root-Tab
   sequence to Tab inside the generation provider picker.
4. **Split the panel.** Extract `settings_menu_host.dart`,
   `settings_plugins.dart`, `settings_providers.dart`,
   `settings_contributions.dart`; shrink `settings_panel.dart` to the shell.
   Move-only; no test may change.
5. **Docs.** Update `docs/engine2-settings.md` (header/scope/Tab wording at
   lines 14–17 and the eligibility note at 54–55: scope is chosen in the leaf
   editor, not at the root), mark this proposal implemented, and note the
   `tina config`/first-run path now sharing the scoped stack.

Order rationale: the factory (1) is what makes the deletion (2) cheap and
reviewable; doing the split (4) after the deletion avoids moving soon-dead
code; 3 before 4 so the split moves the final shape of the scope code.

## Test migration (commit 2)

| File | Today | After |
|---|---|---|
| `settings_panel_test.dart` (621 lines) | `drive()` (62–66) calls `run()` without scoped params — entirely legacy mode | Rebuild `drive()` on the `scoped_settings_test.dart` fixture pattern (`TuiAssembly.start` on a temp config; panel takes `scopedSettings`/`settingsBackend` from it). Provider-form, credential, and limits tests keep their key sequences; expectations against `config` file contents still hold because scoped Global writes land in the same file. |
| `provider_reload_test.dart` | `settings()` helper (78–89) passes only `path`/`descriptors`/`applyConfiguration` | Same fixture port; assertions unchanged. |
| `settings_contributions_test.dart` | Two `run()` calls (157–176) without scoped params | Port; contribution-section behavior is mode-independent. |
| `panels_test.dart` | Root-level Tab (`\t\tGeneration\r`, line 422) to reach Global | Retarget Tab to the generation picker menu (commit 3). |
| `scoped_settings_test.dart`, `plugin_settings_panel_test.dart` | Already scoped | Unchanged except import updates after the split. |
| `app_test.dart`, `app_smoke_test.dart`, `headless_test.dart` | Drive `/settings` through the app | Unchanged. |

## Explicitly out of scope

- No navigator/stack abstraction for breadcrumbs; the two-level browse loop
  stays. Rewriting every drive-based test for that buys little here.
- No credential storage moves (Global-only providers editor stays as is).
- No UI redesign beyond the scope row/Tab placement; layout, search, `?`
  help, Ctrl-R inherit, and the plugin matrix interaction model are unchanged.
- No changes to `tina_settings`/`tina_console` packages beyond what the
  `contextLine` parameter already supports.

## Risks

- **First-run regression.** `tina --configure`/no-config boot now runs the
  scoped stack. Mitigation: commit 2 keeps the existing
  `settings_panel_test` provider-form flows as the smoke for this path; add
  one test running `runConfigEditor` against a fresh temp dir asserting the
  default-model/providers flow still writes the file.
- **Session-scope persistence on first run.** The scoped backend writes
  session overrides into the session snapshot only; `runConfigEditor` has no
  session, so its writes land in Global/Workspace layers (the factory's
  `workspacePath: configPath` makes Workspace ≡ Global there). Called out so
  it is a decision, not an accident.
- **Scope confusion in `_section` contributions.** Controls with their own
  `scopes` restrict the section-local selection; verify against
  `settings_contributions_test.dart`'s scope-picker case.
- **Split-induced regressions.** Commit 4 is move-only and gated by
  "no test file may change", which keeps it honest.

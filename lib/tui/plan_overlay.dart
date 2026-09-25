import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tina/config/terminal_config.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

export 'package:tina/config/terminal_config.dart' show PlanOverlayMode;

/// Paints [text] in SGR [code] (null = default). Injected so the renderer
/// stays a pure function — tests pass a marker paint instead of a backend.
typedef PlanPaint = String Function(String text, String? code);

/// View-model knobs for [renderPlanOverlayLines]. Kept separate from the plan
/// value so the renderer never mutates anything plan-shaped.
class PlanOverlayUi {
  /// Active item only (vs the full list). The host sets this automatically
  /// when the plan does not fit the terminal.
  final bool collapsed;

  /// Roots ([Plan.items] indices) whose subtask subtree is folded. Absent =
  /// expanded; the empty set is "everything expanded", the default.
  final Set<int> collapsedRoots;

  /// Index into the FLATTENED VISIBLE rows (see [_visibleRows]) of the
  /// cycle-selected row (expanded mode only), or null for no selection.
  /// Rendered with a `❯` marker; the host wires Enter to it. Collapsed
  /// subtrees occupy no slot, so one ↓ hop walks past them.
  final int? selectedIndex;

  /// True while focus cycling has highlighted this overlay — the host draws
  /// the box border in the cycling tint instead of dim.
  final bool highlighted;

  /// True while this overlay owns keyboard focus — the footer advertises the
  /// selection keys.
  final bool focused;

  const PlanOverlayUi({
    this.collapsed = false,
    this.collapsedRoots = const {},
    this.selectedIndex,
    this.highlighted = false,
    this.focused = false,
  });
}

/// One visible row of the expanded overlay: an item plus the address the
/// host needs to act on it — which [Plan.items] root it belongs to, which
/// child slot it fills (null for the root row itself), and its indent depth.
class _Row {
  final PlanItem item;
  final int rootIndex;
  final int? childIndex;
  final int depth;

  const _Row({
    required this.item,
    required this.rootIndex,
    required this.childIndex,
    required this.depth,
  });

  /// Only root rows can carry children (nesting is capped at one level).
  bool get hasChildren => childIndex == null && item.children.isNotEmpty;
}

/// The rows the expanded overlay paints: every root row followed by its
/// children — except under roots listed in [collapsedRoots], whose subtrees
/// are skipped entirely (they occupy no slot, hence no selection stop).
List<_Row> _visibleRows(Plan plan, {Set<int> collapsedRoots = const {}}) => [
      for (final (ri, item) in plan.items.indexed) ...[
        _Row(
            item: item,
            rootIndex: ri,
            childIndex: null,
            depth: 0),
        if (!collapsedRoots.contains(ri))
          for (final (ci, child) in item.children.indexed)
            _Row(
                item: child,
                rootIndex: ri,
                childIndex: ci,
                depth: 1),
      ],
    ];

/// Renders the plan overlay box as a list of paintable lines (borders
/// included). Pure: same inputs → byte-identical lines. The host owns
/// geometry, painting and the [OverlayRegion]; this only decides content.
///
/// Shape (expanded, second item carrying a collapsed subtree):
/// ```
/// ┌ plan · 2/5 · needs approval ─┐
/// │ ✓ done item                  │
/// │ ▸ active item (+2)           │   cyan (accent) + fold glyph + count
/// │   · subtask                  │   children indent two spaces
/// │ · pending item               │   dim
/// └ ctrl+p collapse · /plan appr ┘
/// ```
///
/// Selection (focused cycling): the [PlanOverlayUi.selectedIndex] VISIBLE row
/// gains a `❯` marker, and when [PlanOverlayUi.focused] the footer advertises
/// the keys: `enter approve/expand · r reject · ↑↓ select`.
List<String> renderPlanOverlayLines({
  required Plan plan,
  required PlanOverlayUi ui,
  required int width,
  required PlanPaint paint,
}) {
  if (width < 8) return const [];
  final innerW = width - 4; // borders + one padding column each side
  // The header lives in the top border's title slot.
  final header = _headerText(plan);
  final active = plan.allItems
      .where((i) => i.state == PlanState.inProgress)
      .map((i) => i.text)
      .join(' · ');
  final footer = ui.focused
      ? '↑↓ select · ↵ approve/expand · r reject · ␣ toggle item'
      : ui.collapsed
          ? 'ctrl+p expand'
          : 'ctrl+p collapse';

  final rows =
      ui.collapsed ? const <_Row>[] : _visibleRows(plan, collapsedRoots: ui.collapsedRoots);
  final interior = ui.collapsed
      ? <(String, String?)>[
          // Collapsed: only the in-progress row.
          if (active.isNotEmpty) ('▸ $active', 'accent'),
        ]
      : [
          // Expanded: every visible row. The selected row (host-driven,
          // while the overlay is cycled to) swaps its state glyph for a ❯
          // marker; color still encodes the state. Parents show a fold
          // glyph (▾ expanded / ▸ folded) and a dim-ish (+n) count while
          // folded; children indent two spaces per depth.
          for (final (vi, row) in rows.indexed)
            (
              _rowText(row,
                  selected: vi == ui.selectedIndex,
                  collapsedRoots: ui.collapsedRoots),
              switch (row.item.state) {
                PlanState.pending => null,
                PlanState.inProgress => 'accent',
                PlanState.done => 'ok',
              },
            ),
        ];

  // While the focus ring highlights this overlay, its chrome takes the
  // cycling tint instead of dim (same vocabulary the panels use).
  final borderCode = ui.highlighted ? 'highlight' : 'dim';

  final lines = <String>[];
  // Top border with the header embedded, box-drawing style. The title is
  // ellipsized (never silently hard-cut) when it overflows the box.
  final titleSeg = _fit(' $header ', width - 2);
  lines.add(
    '${_p(paint, '┌', borderCode)}'
    '${_p(paint, titleSeg, 'header')}'
    '${_p(paint, '─' * (width - 2 - titleSeg.length), borderCode)}'
    '${_p(paint, '┐', borderCode)}',
  );
  for (final (text, kind) in interior) {
    final shown = _fit(text, innerW);
    final pad = ' ' * (innerW - _visible(shown));
    final styled = switch (kind) {
      'accent' => _p(paint, shown, 'accent'),
      'ok' => _p(paint, shown, 'ok'),
      _ => shown, // pending/header rows render plain, dim padding around
    };
    lines.add(
      '${_p(paint, '│', borderCode)} '
      '$styled$pad'
      ' ${_p(paint, '│', borderCode)}',
    );
  }
  // Footer.
  final footerShown = _fit(footer, innerW);
  final footerPad = ' ' * (innerW - _visible(footerShown));
  lines.add(
    '${_p(paint, '│', borderCode)} '
    '${_p(paint, '$footerShown$footerPad', 'footer')}'
    ' ${_p(paint, '│', borderCode)}',
  );
  lines.add(
    '${_p(paint, '└', borderCode)}'
    '${_p(paint, '─' * (width - 2), borderCode)}'
    '${_p(paint, '┘', borderCode)}',
  );
  return lines;
  // Codes are symbolic ('dim', 'header', 'accent', 'ok', 'highlight') and
  // the HOST maps them to Theme SGR strings via its injected [PlanPaint], so
  // the renderer has no theme dependency at all.
}

/// The glyph + indent + text of one row. A folded parent renders its state
/// glyph slot as the fold caret and appends `(+n)`; the caret wins over the
/// in-progress `▸` so fold state is always visible. The selection marker
/// replaces the glyph on any row.
String _rowText(
  _Row row, {
  required bool selected,
  required Set<int> collapsedRoots,
}) {
  final indent = '  ' * row.depth;
  final folded = row.hasChildren && collapsedRoots.contains(row.rootIndex);
  final marker = selected
      ? '❯'
      : row.hasChildren
          ? (folded ? '▸' : '▾')
          : switch (row.item.state) {
              PlanState.pending => '·',
              PlanState.inProgress => '▸',
              PlanState.done => '✓',
            };
  final hint = folded ? ' (+${row.item.children.length})' : '';
  return '$indent$marker ${row.item.text}$hint';
}

String _p(PlanPaint paint, String text, String kind) {
  final code = switch (kind) {
    'dim' => 'dim',
    'header' => 'header',
    'accent' => 'accent',
    'ok' => 'ok',
    'highlight' => 'highlight',
    _ => null,
  };
  return paint(text, code);
}

String _headerText(Plan plan) {
  final all = plan.allItems.toList();
  final done = all.where((i) => i.state == PlanState.done).length;
  final counts = '${plan.items.isEmpty ? 0 : done}/${all.length}';
  final badge = switch (plan.approval) {
    PlanApproval.none => '',
    PlanApproval.requested => ' · needs approval',
    PlanApproval.approved => ' · approved',
    PlanApproval.rejected => ' · rejected',
  };
  return 'plan · $counts$badge';
}

/// Clip [s] to [maxCols] visible columns with an ellipsis.
String _fit(String s, int maxCols) {
  if (_visible(s) <= maxCols) return s;
  var out = '';
  for (var i = 0; i < s.length;) {
    final size = runeSizeAt(s, i);
    final candidate = out + s.substring(i, i + size);
    if (_visible('$candidate…') > maxCols) break;
    out = candidate;
    i += size;
  }
  return '$out…';
}

int _visible(String s) {
  var w = 0;
  for (var i = 0; i < s.length;) {
    final size = runeSizeAt(s, i);
    w += runeWidth(codePointAt(s, i));
    i += size;
  }
  return w;
}

/// Interior height [renderPlanOverlayLines] needs for [plan] at [collapsed]:
/// the VISIBLE item rows (folded subtrees contribute nothing) or the single
/// active row, plus the footer row.
int planOverlayContentHeight(
  Plan plan, {
  required bool collapsed,
  Set<int> collapsedRoots = const {},
}) {
  if (collapsed) {
    final hasActive =
        plan.allItems.any((i) => i.state == PlanState.inProgress);
    return 1 + (hasActive ? 1 : 0) + 1; // active row? + footer
  }
  return _visibleRows(plan, collapsedRoots: collapsedRoots).length + 1;
}

/// The plan column: an [OverlayRegion] docked inside the chat area's
/// top-right corner, re-rendered on every [PlanStore.changes] event for the
/// FOCUSED conversation (via [conversationId], the same callback the status
/// strip uses).
///
/// It is also a [Focusable]: Ctrl+G cycles highlight it like any panel, and
/// once FOCUSED it claims ↑/↓ (move the selection over the visible rows,
/// collapsed subtrees skipped in one hop), Enter (toggle a parent's subtree
/// open/closed; approve anywhere else — the footer is the dedicated approve
/// stop, reached by ↓ past the last row), `a` (approve), `r` (reject the
/// plan), and space (toggle the selected item pending↔done) — the same store
/// writes `/plan approve|reject|done|pending` perform, so the agent, the
/// status strip, and this overlay all re-render from one source of truth.
/// ←/→ (and every other key) fall through to the shared chat editor / focus
/// ring so typing, paste, and spatial cycling keep working while the overlay
/// is up. Fold state lives only in this overlay's view state — it is never
/// persisted. Collapsed mode and Ctrl+P (wired by the coordinator to
/// [toggle]) behave as before; the overlay is only focusable while its
/// region is painted.
///
/// Visibility: [PlanOverlayMode.auto] shows the overlay whenever the
/// conversation has a plan (degrading to collapsed when it does not fit);
/// [manual] only after Ctrl+P; [off] constructs nothing (the coordinator
/// skips [start]). Ctrl+P records a user override that wins over the mode
/// until toggled back.
class PlanOverlay implements Focusable {
  PlanOverlay({
    required this.screen,
    required this.store,
    required this.conversationId,
    this.focusManager,
    this.mode = PlanOverlayMode.auto,
    this.onApprove,
    this.onReject,
    this.onSpace,
  });

  final Screen screen;
  final PlanStore store;
  final String Function() conversationId;
  final PlanOverlayMode mode;

  /// Focus ring this overlay joins when started. The overlay unregisters
  /// itself in [dispose]; [FocusManager] skips it while hidden via
  /// [canFocus].
  final FocusManager? focusManager;

  /// Plan action hooks, mirroring `/plan`. When [onApprove]/[onReject] are
  /// null the overlay writes the store directly (the same thing the command
  /// does). [onSpace] defaults to the per-item pending↔done toggle.
  final void Function()? onApprove;
  final void Function()? onReject;
  final void Function()? onSpace;

  OverlayRegion? _region;
  StreamSubscription<void>? _sub;
  bool _started = false;
  bool _focused = false;
  bool _highlighted = false;

  /// Index into the VISIBLE rows of the current plan (see [_rows]).
  int? _selected;

  /// True when ↓ has moved past the last row onto the footer (the dedicated
  /// approve stop). Only reachable when the plan has any subtasks, so plain
  /// plans keep the old clamp-at-the-ends behavior.
  bool _onFooter = false;

  /// [Plan.items] indices with folded subtrees. Pure view state: never
  /// persisted, reset when the overlay hides.
  final Set<int> _collapsedRoots = {};

  /// User override: null = follow [mode]; true/false = forced show/hide.
  bool? _userOverride;

  /// Test/debug surface: whether the overlay region is currently painted.
  @visibleForTesting
  bool get regionVisible => _region?.isVisible ?? false;

  /// True while this overlay holds focus — visible only in debug/test
  /// surfaces that need it; the ring's source of truth is [FocusManager].
  @visibleForTesting
  bool get debugFocused => _focused;

  // -- Focusable ------------------------------------------------------------

  @override
  bool get hasFocus => _focused;

  /// Only focusable while painted: a hidden overlay would be a ring entry
  /// that highlights nothing and swallows keys.
  @override
  bool get canFocus => _region?.isVisible ?? false;

  /// The painted box while shown (so spatial cycling reaches it); the empty
  /// rect while hidden takes it out of spatial navigation.
  @override
  Rect get bounds =>
      (_region?.isVisible ?? false) ? _region!.bounds : Rect.empty;

  @override
  void focus() {
    _focused = true;
    _highlighted = false;
    _onFooter = false;
    _setSelected(firstActionableIndex);
    render();
  }

  @override
  void blur() {
    _focused = false;
    _selected = null;
    _onFooter = false;
    render();
  }

  @override
  void highlight() {
    _highlighted = true;
    render();
  }

  @override
  void unhighlight() {
    _highlighted = false;
    render();
  }

  @override
  bool handleEvent(InputEvent event) {
    if (!_focused) return false;
    if (event is ScrollEvent) {
      _onFooter = false;
      _setSelected((_selected ?? 0) + (event.up ? -1 : 1));
      return true;
    }
    if (event is ArrowKey) {
      switch (event.direction) {
        case ArrowDirection.up:
          if (_onFooter) {
            _onFooter = false;
            render();
          } else {
            _setSelected((_selected ?? 0) - 1);
          }
        case ArrowDirection.down:
          final current = _selected ?? -1;
          if (_onFooter) break; // stay parked on the approve stop
          // With subtasks in play, ↓ past the last row parks on the footer
          // (the approve stop); without them the selection clamps as before.
          if (_rows.any((r) => r.hasChildren) && current >= _rows.length - 1) {
            _onFooter = true;
            render();
          } else {
            _setSelected(current + 1);
          }
        case ArrowDirection.pageUp:
          _onFooter = false;
          _setSelected(0);
        case ArrowDirection.pageDown:
        case ArrowDirection.left:
        case ArrowDirection.right:
          return false; // spatial cycling keys must reach the focus ring
      }
      return true;
    }
    if (event is ControlKey) {
      // Enter toggles a selected parent's subtree; anywhere else (or on the
      // footer) it approves — an armed prompt routes it to the focused panel
      // before submit; the footer advertises it. Every other control combo
      // stays with the editor/global handlers (Ctrl+P toggles this overlay,
      // Ctrl+W kills a word, Ctrl+C interrupts…). Only plain arrows and the
      // verbs are ours.
      if (event.code == ControlCode.enter) {
        final row = _selectedRow;
        if (!_onFooter && row != null && row.hasChildren) {
          _toggleExpanded(row.rootIndex);
          return true;
        }
        (onApprove ?? _approve)();
        return true;
      }
      return false;
    }
    if (event is EscapeKey) return false;
    if (event is CharInput) {
      switch (event.text) {
        case 'a' || 'A':
          (onApprove ?? _approve)();
          return true;
        case 'r' || 'R':
          (onReject ?? _reject)();
          return true;
        case ' ' when onSpace != null:
          onSpace!();
          return true;
        case ' ':
          _toggleItem();
          return true;
      }
      return false; // typing must reach the chat editor
    }
    return false;
  }

  /// Enter/`a`: mirror `/plan approve` (the active item advances as the agent
  /// works; done items stay done). No-op without a plan.
  void _approve() {
    final id = conversationId();
    if (store.read(id).isEmpty) return;
    store.approve(id);
    refresh();
  }

  /// `r`: mirror `/plan reject`.
  void _reject() {
    final id = conversationId();
    if (store.read(id).isEmpty) return;
    store.reject(id);
    refresh();
  }

  /// Fold/unfold a root's subtree. Pure view state — the store is untouched,
  /// so this repaints directly instead of waiting for a change event.
  void _toggleExpanded(int rootIndex) {
    if (!_collapsedRoots.remove(rootIndex)) _collapsedRoots.add(rootIndex);
    _clampSelected();
    render();
  }

  /// Space: toggle the selected item pending↔done (the `/plan done <n>` /
  /// `/plan pending <n>` pair), parent or child alike; parents and children
  /// tick independently (no auto done). Refresh comes from the store's
  /// change stream.
  void _toggleItem() {
    final id = conversationId();
    final plan = store.read(id);
    final row = _selectedRow;
    if (plan.isEmpty || row == null) return;
    PlanState flip(PlanState s) =>
        s == PlanState.done ? PlanState.pending : PlanState.done;
    final parent = plan.items[row.rootIndex];
    final PlanItem updated;
    if (row.childIndex == null) {
      updated = parent.copyWith(state: flip(parent.state));
    } else {
      updated = parent.copyWith(
        children: [
          for (final (ci, child) in parent.children.indexed)
            ci == row.childIndex ? child.copyWith(state: flip(child.state)) : child,
        ],
      );
    }
    try {
      store.update(id, [
        for (final (i, it) in plan.items.indexed) i == row.rootIndex ? updated : it,
      ]);
    } on ArgumentError {
      return; // mirror /plan: a rejected update just keeps the old plan
    }
  }

  /// The rows the overlay would paint right now (expanded geometry — the
  /// selection only exists in expanded mode; collapsed overlays hide it).
  List<_Row> get _rows =>
      _visibleRows(store.read(conversationId()), collapsedRoots: _collapsedRoots);

  /// The row under the selection, or null when nothing is selected
  /// (collapsed geometry, hidden, blurred, out of range, or parked on the
  /// footer approve stop).
  _Row? get _selectedRow {
    if (_onFooter) return null;
    final i = _selected;
    final rows = _rows;
    if (i == null || i < 0 || i >= rows.length) return null;
    return rows[i];
  }

  /// Row item under the selection, or null when nothing is selected.
  PlanItem? get selectedItem => _selectedRow?.item;

  /// First non-done VISIBLE row, or 0 — where focusing lands the selection.
  int get firstActionableIndex {
    final i = _rows.indexWhere((row) => row.item.state != PlanState.done);
    return i < 0 ? 0 : i;
  }

  void _setSelected(int i) {
    final count = _rows.length;
    if (count == 0) return;
    final next = i.clamp(0, count - 1);
    if (next == _selected) return;
    _selected = next;
    render();
  }

  /// Keep the selection inside the visible rows after the row list shrank
  /// (a subtree folded, a plan update removed rows).
  void _clampSelected() {
    final count = _rows.length;
    if (count == 0) {
      _selected = null;
      _onFooter = false;
    } else if (_selected != null && _selected! >= count) {
      _selected = count - 1;
    }
  }

  /// Repaint when any visual input to the chrome changed (selection, focus,
  /// highlight). No-op while hidden — [refresh] paints these flags.
  void render() {
    if (!(_region?.isVisible ?? false)) return;
    refresh();
  }

  /// The plan width: capped, and never wider than the chat area.
  static const _maxWidth = 44;

  bool get _wantVisible {
    final override = _userOverride;
    if (override != null) return override;
    return mode == PlanOverlayMode.auto;
  }

  void start() {
    if (_started) return;
    _started = true;
    focusManager?.register(this);
    _sub = store.changes.listen((_) => refresh(),
        onError: (Object _) => refresh());
    refresh();
  }

  /// Ctrl+P: hidden → shown → hidden. Consumed by the editor hook whenever
  /// the overlay exists (even when nothing changes visually — off-mode never
  /// constructs one).
  void toggle() {
    _userOverride = !_wantVisible;
    refresh();
  }

  /// Recompute bounds + repaint (resize, or a layout change).
  void relayout() => refresh();

  /// Re-read the focused conversation's plan and repaint or hide.
  void refresh() {
    if (!_started) return;
    final plan = store.read(conversationId());
    final show = !plan.isEmpty && _wantVisible;
    if (!show) {
      _hide();
      return;
    }
    _clampSelected();
    final layout = screen.layout;
    final chat = layout.chat;
    final width = _maxWidth < chat.width ? _maxWidth : chat.width;
    // Collapsed when the full list cannot fit between the borders; an
    // already-collapsed box that still does not fit hides entirely.
    var collapsed = planOverlayContentHeight(plan,
            collapsed: false, collapsedRoots: _collapsedRoots) +
            2 >
        chat.height;
    if (collapsed &&
        planOverlayContentHeight(plan,
                collapsed: true, collapsedRoots: _collapsedRoots) +
            2 >
            chat.height) {
      _hide();
      return;
    }
    final ui = PlanOverlayUi(
      collapsed: collapsed,
      collapsedRoots: _collapsedRoots,
      selectedIndex: _focused && !_onFooter ? _selected : null,
      highlighted: _highlighted,
      focused: _focused,
    );
    final height = (planOverlayContentHeight(plan,
                collapsed: collapsed, collapsedRoots: _collapsedRoots) +
            2)
        .clamp(3, chat.height);
    final bounds = Rect(
      row: layout.topBorderRow + 1,
      col: chat.col + chat.width - width,
      width: width,
      height: height,
    );
    final lines = renderPlanOverlayLines(
      plan: plan,
      ui: ui,
      width: width,
      paint: _themePaint,
    );
    final region = _region ??= OverlayRegion(screen, bounds);
    region.update(bounds: bounds, lines: lines);
  }

  /// Symbolic code → Theme SGR string. The same vocabulary the renderer
  /// emits (`dim`/`header`/`accent`/`ok`/`highlight`), so a custom theme
  /// restyles the overlay with the config.
  String _themePaint(String text, String? code) {
    if (text.isEmpty) return text;
    final theme = screen.theme;
    final sgr = switch (code) {
      'dim' => theme.chat.dim,
      'accent' => theme.chat.cyan,
      'ok' => theme.chat.green,
      'highlight' => theme.chat.yellow,
      // Pending rows render in the default style.
      _ => null,
    };
    return sgr == null ? text : screen.colorize(sgr, text);
  }

  void _hide() {
    final region = _region;
    // Dropping off-screen drops our claims: no selection, no footer stop, no
    // highlight, and not focused — a stale focused flag would let a/r/space
    // act on an invisible panel. (A stale [FocusManager.focused] pointer is
    // harmless: [handleEvent] no-ops while unfocused, and the ring skips us
    // via [canFocus].) Fold state is deliberately kept: it is cosmetic view
    // state, not a claim on input.
    _focused = false;
    _highlighted = false;
    _selected = null;
    _onFooter = false;
    if (region == null) return;
    region.hide();
  }

  void dispose() {
    _started = false;
    focusManager?.unregister(this);
    _sub?.cancel();
    _sub = null;
    _region?.dispose();
    _region = null;
  }
}

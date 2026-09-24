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

  /// Index into [Plan.items] of the cycle-selected row (expanded mode only),
  /// or null for no selection. Rendered with a `❯` marker; the host wires
  /// Enter to it.
  final int? selectedIndex;

  /// True while focus cycling has highlighted this overlay — the host draws
  /// the box border in the cycling tint instead of dim.
  final bool highlighted;

  /// True while this overlay owns keyboard focus — the footer advertises the
  /// selection keys.
  final bool focused;

  const PlanOverlayUi({
    this.collapsed = false,
    this.selectedIndex,
    this.highlighted = false,
    this.focused = false,
  });
}

/// Renders the plan overlay box as a list of paintable lines (borders
/// included). Pure: same inputs → byte-identical lines. The host owns
/// geometry, painting and the [OverlayRegion]; this only decides content.
///
/// Shape (expanded):
/// ```
/// ┌ plan · 2/5 · needs approval ─┐
/// │ ✓ done item                  │
/// │ ▸ active item                │   cyan (accent) + spinner-free ▸
/// │ · pending item               │   dim
/// └ ctrl+p collapse · /plan appr ┘
/// ```
///
/// Selection (focused cycling): the [PlanOverlayUi.selectedIndex] row gains a
/// `❯` marker, and when [PlanOverlayUi.focused] the footer advertises the
/// keys: `enter approve · r reject · ↑↓ select`.
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
  final active = plan.items
      .where((i) => i.state == PlanState.inProgress)
      .map((i) => i.text)
      .join(' · ');
  final footer = ui.focused
      ? '↑↓ select · ↵ approve · r reject · ␣ toggle item'
      : ui.collapsed
          ? 'ctrl+p expand'
          : 'ctrl+p collapse';

  final interior = ui.collapsed
      ? <(String, String?)>[
          // Collapsed: only the in-progress row.
          if (active.isNotEmpty) ('▸ $active', 'accent'),
        ]
      : [
          // Expanded: every item. The selected row (host-driven, while the
          // overlay is cycled to) swaps its state glyph for a ❯ marker;
          // color still encodes the state.
          for (final (index, item) in plan.items.indexed)
            (
              '${index == ui.selectedIndex ? '❯' : switch (item.state) {
                PlanState.pending => '·',
                PlanState.inProgress => '▸',
                PlanState.done => '✓',
              }} ${item.text}',
              switch (item.state) {
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
  final done = plan.items.where((i) => i.state == PlanState.done).length;
  final counts = '${plan.items.isEmpty ? 0 : done}/${plan.items.length}';
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
/// the item rows (or the single active row) plus the footer row.
int planOverlayContentHeight(Plan plan, {required bool collapsed}) {
  if (collapsed) {
    final hasActive =
        plan.items.any((i) => i.state == PlanState.inProgress);
    return 1 + (hasActive ? 1 : 0) + 1; // active row? + footer
  }
  return plan.items.length + 1; // items + footer
}

/// The plan column: an [OverlayRegion] docked inside the chat area's
/// top-right corner, re-rendered on every [PlanStore.changes] event for the
/// FOCUSED conversation (via [conversationId], the same callback the status
/// strip uses).
///
/// It is also a [Focusable]: Ctrl+G cycles highlight it like any panel, and
/// once FOCUSED it claims ↑/↓ (move the selection), Enter/`a` (approve the
/// plan), `r` (reject the plan), and space (toggle the selected item
/// pending↔done) — the same store writes `/plan approve|reject|done|pending`
/// perform, so the agent, the status strip, and this overlay all re-render
/// from one source of truth. Everything else (text, paste, other keys) falls
/// through to the shared chat editor so typing/streaming keeps working while
/// the overlay is up. Collapsed mode and Ctrl+P (wired by the coordinator to
/// [toggle]) behave as before; the overlay is only focusable while its region
/// is painted.
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
  int? _selected;

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
    _setSelected(firstActionableIndex);
    render();
  }

  @override
  void blur() {
    _focused = false;
    _selected = null;
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
      _setSelected((_selected ?? 0) + (event.up ? -1 : 1));
      return true;
    }
    if (event is ArrowKey) {
      switch (event.direction) {
        case ArrowDirection.up:
          _setSelected((_selected ?? 0) - 1);
        case ArrowDirection.down:
          _setSelected((_selected ?? 0) + 1);
        case ArrowDirection.pageUp:
          _setSelected(0);
        case ArrowDirection.pageDown:
        case ArrowDirection.left:
        case ArrowDirection.right:
          return false; // spatial cycling keys must reach the focus ring
      }
      return true;
    }
    if (event is ControlKey) {
      // Enter approves (an armed prompt routes it to the focused panel before
      // submit; the footer advertises it). Every other control combo stays
      // with the editor/global handlers (Ctrl+P toggles this overlay, Ctrl+W
      // kills a word, Ctrl+C interrupts…). Only plain arrows and the verbs
      // are ours.
      if (event.code == ControlCode.enter) {
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

  /// Space: toggle the selected item pending↔done (the `/plan done <n>` /
  /// `/plan pending <n>` pair). Refresh comes from the store's change stream.
  void _toggleItem() {
    final id = conversationId();
    final plan = store.read(id);
    final item = selectedItem;
    if (plan.isEmpty || item == null) return;
    final index = plan.items.indexOf(item);
    if (index < 0) return;
    try {
      store.update(id, [
        for (final (i, it) in plan.items.indexed)
          (
            text: it.text,
            state: i == index
                ? (it.state == PlanState.done
                    ? PlanState.pending
                    : PlanState.done)
                : it.state,
          ),
      ]);
    } on ArgumentError {
      return; // mirror /plan: a rejected update just keeps the old plan
    }
  }

  /// Row under the selection, or null when nothing is selected (collapsed,
  /// hidden, or blurred).
  ({String text, PlanState state})? get selectedItem {
    final i = _selected;
    final items = store.read(conversationId()).items;
    if (i == null || i < 0 || i >= items.length) return null;
    return items[i];
  }

  /// First non-done item, or 0 — where focusing lands the selection.
  int get firstActionableIndex {
    final items = store.read(conversationId()).items;
    final i = items.indexWhere((item) => item.state != PlanState.done);
    return i < 0 ? 0 : i;
  }

  void _setSelected(int i) {
    final count = store.read(conversationId()).items.length;
    if (count == 0) return;
    final next = i.clamp(0, count - 1);
    if (next == _selected) return;
    _selected = next;
    render();
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
    final layout = screen.layout;
    final chat = layout.chat;
    final width = _maxWidth < chat.width ? _maxWidth : chat.width;
    // Collapsed when the full list cannot fit between the borders; an
    // already-collapsed box that still does not fit hides entirely.
    var collapsed = planOverlayContentHeight(plan, collapsed: false) + 2 >
        chat.height;
    if (collapsed &&
        planOverlayContentHeight(plan, collapsed: true) + 2 > chat.height) {
      _hide();
      return;
    }
    final ui = PlanOverlayUi(
      collapsed: collapsed,
      selectedIndex: _focused ? _selected : null,
      highlighted: _highlighted,
      focused: _focused,
    );
    final height =
        (planOverlayContentHeight(plan, collapsed: collapsed) + 2)
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
    // Dropping off-screen drops our claims: no selection, no highlight, and
    // not focused — a stale focused flag would let a/r/space act on an
    // invisible panel. (A stale [FocusManager.focused] pointer is harmless:
    // [handleEvent] no-ops while unfocused, and the ring skips us via
    // [canFocus].)
    _focused = false;
    _highlighted = false;
    _selected = null;
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

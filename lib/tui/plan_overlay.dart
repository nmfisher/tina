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

  const PlanOverlayUi({this.collapsed = false});
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
  final footer = ui.collapsed ? 'ctrl+p expand' : 'ctrl+p collapse';

  final interior = ui.collapsed
      ? <(String, String?)>[
          // Collapsed: only the in-progress row.
          if (active.isNotEmpty) ('▸ $active', 'active'),
        ]
      : [
          // Expanded: every item.
          for (final item in plan.items)
            (
              switch (item.state) {
                PlanState.pending => '· ${item.text}',
                PlanState.inProgress => '▸ ${item.text}',
                PlanState.done => '✓ ${item.text}',
              },
              switch (item.state) {
                PlanState.pending => null,
                PlanState.inProgress => 'active',
                PlanState.done => 'done',
              },
            ),
        ];

  final lines = <String>[];
  // Top border with the header embedded, box-drawing style. The title is
  // ellipsized (never silently hard-cut) when it overflows the box.
  final titleSeg = _fit(' $header ', width - 2);
  lines.add(
    '${_p(paint, '┌', 'border')}'
    '${_p(paint, titleSeg, 'header')}'
    '${_p(paint, '─' * (width - 2 - titleSeg.length), 'border')}'
    '${_p(paint, '┐', 'border')}',
  );
  for (final (text, kind) in interior) {
    final shown = _fit(text, innerW);
    final pad = ' ' * (innerW - _visible(shown));
    final styled = switch (kind) {
      'active' => _p(paint, shown, 'active'),
      'done' => _p(paint, shown, 'done'),
      _ => shown, // pending/header rows render plain, dim padding around
    };
    lines.add(
      '${_p(paint, '│', 'border')} '
      '$styled$pad'
      ' ${_p(paint, '│', 'border')}',
    );
  }
  // Footer.
  final footerShown = _fit(footer, innerW);
  final footerPad = ' ' * (innerW - _visible(footerShown));
  lines.add(
    '${_p(paint, '│', 'border')} '
    '${_p(paint, '$footerShown$footerPad', 'footer')}'
    ' ${_p(paint, '│', 'border')}',
  );
  lines.add(
    '${_p(paint, '└', 'border')}'
    '${_p(paint, '─' * (width - 2), 'border')}'
    '${_p(paint, '┘', 'border')}',
  );
  return lines;
  // Codes are symbolic ('border', 'active', 'done', 'header', 'footer') and
  // the HOST maps them to Theme SGR strings via its injected [PlanPaint], so
  // the renderer has no theme dependency at all.
}

String _p(PlanPaint paint, String text, String kind) {
  final code = switch (kind) {
    'border' => 'dim',
    'header' => 'header',
    'active' => 'accent',
    'done' => 'ok',
    'footer' => 'dim',
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

/// The non-modal, always-live plan column.
///
/// Owns an [OverlayRegion] docked inside the chat area's top-right corner and
/// re-renders it on every [PlanStore.changes] event for the FOCUSED
/// conversation (via [conversationId], the same callback the status strip
/// uses). Never touches the keyboard: Ctrl+P (wired by the coordinator to
/// [toggle]) and `/plan` are the only inputs, so typing/streaming keeps
/// working while the overlay is up.
///
/// Visibility: [PlanOverlayMode.auto] shows the overlay whenever the
/// conversation has a plan (degrading to collapsed when it does not fit);
/// [manual] only after Ctrl+P; [off] constructs nothing (the coordinator
/// skips [start]). Ctrl+P records a user override that wins over the mode
/// until toggled back.
class PlanOverlay {
  PlanOverlay({
    required this.screen,
    required this.store,
    required this.conversationId,
    this.mode = PlanOverlayMode.auto,
  });

  final Screen screen;
  final PlanStore store;
  final String Function() conversationId;
  final PlanOverlayMode mode;

  OverlayRegion? _region;
  StreamSubscription<void>? _sub;
  bool _started = false;

  /// User override: null = follow [mode]; true/false = forced show/hide.
  bool? _userOverride;

  /// Test/debug surface: whether the overlay region is currently painted.
  @visibleForTesting
  bool get regionVisible => _region?.isVisible ?? false;

  /// Test/debug surface: the painted bounds, or null while hidden.
  @visibleForTesting
  Rect? get bounds => (_region?.isVisible ?? false) ? _region!.bounds : null;

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
    final ui = PlanOverlayUi(collapsed: collapsed);
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
  /// emits (`border`/`header`/`active`/`done`/`footer`), so a custom theme
  /// restyles the overlay with the config.
  String _themePaint(String text, String? code) {
    if (text.isEmpty) return text;
    final theme = screen.theme;
    final sgr = switch (code) {
      'header' || 'footer' => theme.chat.dim,
      'active' => theme.chat.cyan,
      'done' => theme.chat.green,
      // 'border' and pending rows render in the default style.
      _ => null,
    };
    return sgr == null ? text : screen.colorize(sgr, text);
  }

  void _hide() {
    final region = _region;
    if (region == null) return;
    region.hide();
  }

  void dispose() {
    _started = false;
    _sub?.cancel();
    _sub = null;
    _region?.dispose();
    _region = null;
  }
}

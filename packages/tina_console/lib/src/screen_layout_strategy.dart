/// Screen-level layout strategies: [LayoutStrategy] plus the policy
/// knobs that reshape the chat screen's template itself.
///
/// A plain [LayoutStrategy] (the wasm `tina:layout@1.0.0` shape) only
/// sizes the tracks of the spec it is handed. Native strategies are
/// trusted code, so [ScreenLayoutStrategy] may additionally override
/// the template policy — whether the screen splits at all, at what
/// width, with which weights, and which side the info column takes.
/// This extension has no wasm counterpart: plugins there never reshape
/// the template, only the track sizes.
library;

import 'package:tina_layout/tina_layout.dart';

import 'screen_layout.dart';

/// Template policy overrides for one screen size. Null fields keep the
/// core default. Returned by [ScreenLayoutStrategy.policyFor].
final class ScreenPolicy {
  const ScreenPolicy({
    this.forceSplit,
    this.minSplitWidth,
    this.chatWeight,
    this.infoWeight,
    this.mirror,
  });

  /// Force the chat/info split on (never off — a false keeps the app's
  /// own decision). `focus` uses this to split at widths the default
  /// strategy would keep single-column.
  final bool? forceSplit;

  /// The narrowest usable width for a split (default 50 columns).
  final int? minSplitWidth;

  /// Column weights of the chat and info tracks (default 65/35).
  final int? chatWeight;

  final int? infoWeight;

  /// Put the info column on the LEFT of the chat box (default false).
  final bool? mirror;
}

/// A [LayoutStrategy] that may also reshape the chat screen template.
///
/// [policyFor] sees the same clamped inputs [ScreenLayout.fromSize]
/// computes (post sidebar reservation) and must be pure; throwing or
/// returning null keeps every core default.
abstract interface class ScreenLayoutStrategy implements LayoutStrategy {
  ScreenPolicy? policyFor(
      {required int width,
      required int height,
      required bool hasMenuBar,
      required int sidebarWidth});
}

/// The width at which the preset strategies split instead of following
/// the default's 100-column threshold: two usable halves of 40 columns.
const int presetSplitWidth = 80;

/// `focus` — equal-share everywhere: weighted tracks split the space
/// equally (65/35 becomes 50/50) and the screen splits as soon as two
/// usable halves fit (80 columns), instead of the default's 100.
///
/// The solve is the generic [FocusLayoutStrategy] ported from the wasm
/// round's `tina/layout-focus`; only the policy part is native.
final class FocusScreenStrategy implements ScreenLayoutStrategy {
  const FocusScreenStrategy();

  @override
  String get id => 'focus';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'focus',
        version: '1.0.0',
        description: 'Equal halves: 50/50 chat/info from 80 columns '
            '(the native form of tina/layout-focus).',
      );

  @override
  ScreenPolicy? policyFor(
          {required int width,
          required int height,
          required bool hasMenuBar,
          required int sidebarWidth}) =>
      ScreenPolicy(
          forceSplit: width - sidebarWidth >= presetSplitWidth,
          minSplitWidth: presetSplitWidth,
          chatWeight: 50,
          infoWeight: 50);

  @override
  GridSolution solveSpec(GridSpec spec,
          {required int columns,
          required int rows,
          CellMetrics metrics = CellMetrics.standard}) =>
      const FocusLayoutStrategy().solveSpec(spec,
          columns: columns, rows: rows, metrics: metrics);
}

/// `two-column` — the mirrored screen: the info column moves to the
/// LEFT (38%), the chat box to the RIGHT (62%), split from 80 columns.
/// The transcript and the info panel sit side by side, info first.
///
/// Track sizing stays the built-in solver's; only the template flips.
final class TwoColumnScreenStrategy implements ScreenLayoutStrategy {
  const TwoColumnScreenStrategy();

  @override
  String get id => 'two-column';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'two-column',
        version: '1.0.0',
        description: 'Info panel left (38%), transcript right (62%), '
            'split from 80 columns.',
      );

  @override
  ScreenPolicy? policyFor(
          {required int width,
          required int height,
          required bool hasMenuBar,
          required int sidebarWidth}) =>
      ScreenPolicy(
          forceSplit: width - sidebarWidth >= presetSplitWidth,
          minSplitWidth: presetSplitWidth,
          chatWeight: 62,
          infoWeight: 38,
          mirror: true);

  @override
  GridSolution solveSpec(GridSpec spec,
          {required int columns,
          required int rows,
          CellMetrics metrics = CellMetrics.standard}) =>
      const BuiltinLayoutStrategy().solveSpec(spec,
          columns: columns, rows: rows, metrics: metrics);
}

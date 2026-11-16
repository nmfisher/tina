import 'geometry.dart';
import 'spec.dart';

/// A rectangle in square units (debug/test view of a solved item).
final class UnitRect {
  final double col;
  final double row;
  final double width;
  final double height;

  const UnitRect(
      {required this.col,
      required this.row,
      required this.width,
      required this.height});

  @override
  String toString() => 'UnitRect(col: $col, row: $row, w: $width, h: $height)';
}

/// Result of [GridSolver.solve].
final class GridSolution {
  /// Terminal size the grid was solved for, in cells.
  final int columns;
  final int rows;

  /// Metrics used for the unit <-> cell conversions.
  final CellMetrics metrics;

  /// Solved item rects in terminal CELLS, keyed by item id.
  ///
  /// Rects are never negative and never extend past the terminal. Dropped
  /// items (see [dropped]) have no entry. An item whose tracks collapsed
  /// has an empty rect (`width`/`height` 0), not a missing one.
  final Map<String, GridRect> rects;

  /// The same rects in square units (before cell snapping).
  final Map<String, UnitRect> unitRects;

  /// Final track sizes in units, for tests and debugging.
  final List<double> columnTrackSizes;
  final List<double> rowTrackSizes;

  /// Items removed because they did not fit, in removal order, with the
  /// reason (`overflow` for the priority policy, `no-room` for auto-flow,
  /// `no-tracks` for an empty template).
  final List<GridDrop> dropped;

  /// Units by which track minimums exceeded the terminal on each axis
  /// after all shrinking (and item drops). 0 when everything fit.
  final double overflowUnitsX;
  final double overflowUnitsY;

  /// Units left unused at the far edge of each axis (span - used).
  final double trailingGapUnitsX;
  final double trailingGapUnitsY;

  const GridSolution({
    required this.columns,
    required this.rows,
    required this.metrics,
    required this.rects,
    required this.unitRects,
    required this.columnTrackSizes,
    required this.rowTrackSizes,
    required this.dropped,
    required this.overflowUnitsX,
    required this.overflowUnitsY,
    required this.trailingGapUnitsX,
    required this.trailingGapUnitsY,
  });

  bool get hasOverflow =>
      overflowUnitsX > GridSolver.epsilon ||
      overflowUnitsY > GridSolver.epsilon;

  /// The item whose rect contains the cell, if any. When rects overlap the
  /// item placed later by the solver wins (topmost), matching paint order.
  String? hitTest(int cellCol, int cellRow) {
    String? hit;
    for (final entry in rects.entries) {
      if (entry.value.contains(cellCol, cellRow)) hit = entry.key;
    }
    return hit;
  }

  GridRect? rectOf(String id) => rects[id];
}

/// Solves a [GridSpec] against a terminal size.
///
/// Pure function: `solve(spec, columns, rows)` → [GridSolution]. No I/O, no
/// clock, no renderer — deterministic for identical inputs on every
/// platform, which is what lets the native and wasm TUIs share specs.
///
/// Pass order per solve (one deterministic pass per axis):
///
/// 1. Placement — explicit items are clamped into the template; items with
///    an auto axis are placed first-fit row-major (a sparse cursor that
///    never backtracks). Items that do not fit are dropped (`no-room`).
/// 2. Columns — fixed tracks at their size; `auto` tracks from item content
///    minimums; `weighted` tracks share the remainder by weight
///    (largest-remainder rounding; ties to the earlier track), all clamped
///    to their min/max.
/// 3. Rows — the same pass, plus aspect hints: an item with a
///    [GridItem.aspectHint] in an `auto` row track sizes that track from
///    its solved column width (`height = width / aspectHint`), clamped to
///    the item and track bounds.
/// 4. Reconciliation — if minimums overrun the span, auto then weighted
///    tracks shrink toward their minimums (largest surplus first). If the
///    overrun persists, the lowest-priority size-contributing item is
///    dropped and the grid re-solved (later declarations drop first among
///    equals). Edges are always clamped to the terminal: rects are never
///    negative and never extend past the screen.
final class GridSolver {
  static const double epsilon = 1e-9;

  /// Solve [spec] for a terminal of [columns] x [rows] cells.
  static GridSolution solve(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final spanX = columns.toDouble();
    final spanY = rows / metrics.rowsPerUnit;

    var items = List<GridItem>.of(spec.items);
    final policyDrops = <GridDrop>[];
    var grid = _solveOnce(
        spec.columns, spec.rows, items, spanX, spanY, metrics);

    // Overflow policy: while minimums cannot fit, drop the lowest-priority
    // item that contributes a size (ties: the later declaration goes
    // first — the newest overlay, not the chat transcript).
    while (grid.overflowX > epsilon || grid.overflowY > epsilon) {
      var victim = -1;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final contributes = item.minWidthUnits > epsilon ||
            item.minHeightUnits > epsilon ||
            item.aspectHint != null;
        if (!contributes) continue;
        if (victim < 0 || item.priority <= items[victim].priority) {
          victim = i;
        }
      }
      if (victim < 0) break; // Overflow is from template minimums alone.
      policyDrops.add(GridDrop(id: items[victim].id, reason: 'overflow'));
      items.removeAt(victim);
      grid = _solveOnce(spec.columns, spec.rows, items, spanX, spanY, metrics);
    }

    return GridSolution(
      columns: columns,
      rows: rows,
      metrics: metrics,
      rects: grid.rects,
      unitRects: grid.unitRects,
      columnTrackSizes: grid.columnSizes,
      rowTrackSizes: grid.rowSizes,
      dropped: [...policyDrops, ...grid.placementDrops],
      overflowUnitsX: grid.overflowX,
      overflowUnitsY: grid.overflowY,
      trailingGapUnitsX: grid.trailingGapX,
      trailingGapUnitsY: grid.trailingGapY,
    );
  }

  static _SolvedGrid _solveOnce(List<GridTrack> colTracks,
      List<GridTrack> rowTracks, List<GridItem> items,
      double spanX, double spanY, CellMetrics metrics) {
    // -- 1. Placement ------------------------------------------------------
    final placementDrops = <GridDrop>[];
    if (colTracks.isEmpty || rowTracks.isEmpty) {
      for (final item in items) {
        placementDrops.add(GridDrop(id: item.id, reason: 'no-tracks'));
      }
      return _SolvedGrid.empty(colTracks.length, rowTracks.length,
          const {}, const {}, placementDrops);
    }

    final placements = <_Placement>[];
    final occupied = <int>{};
    final autoItems = <GridItem>[];
    for (final item in items) {
      if (item.column.start != null && item.row.start != null) {
        final p = _Placement.explicit(item, colTracks, rowTracks);
        placements.add(p);
        _occupy(occupied, colTracks.length, p);
      } else {
        autoItems.add(item);
      }
    }

    var cursorRow = 0;
    var cursorCol = 0;
    for (final item in autoItems) {
      final colSpan = item.column.span.clamp(1, colTracks.length);
      final rowSpan = item.row.span.clamp(1, rowTracks.length);
      final colFixed = item.column.start != null;
      final rowFixed = item.row.start != null;
      final lockCol =
          colFixed ? (item.column.start!).clamp(0, colTracks.length - colSpan) : 0;
      final lockRow =
          rowFixed ? (item.row.start!).clamp(0, rowTracks.length - rowSpan) : 0;
      _Placement? placed;
      var r = rowFixed ? lockRow : cursorRow;
      while (placed == null && r + rowSpan <= rowTracks.length) {
        var c = colFixed ? lockCol : (r == cursorRow ? cursorCol : 0);
        while (c + colSpan <= colTracks.length) {
          if (_fits(occupied, colTracks.length, c, colSpan, r, rowSpan)) {
            placed = _Placement(item, c, colSpan, r, rowSpan);
            break;
          }
          c++;
        }
        if (placed != null) break;
        if (rowFixed) break; // Locked row: one pass over the columns.
        r++;
      }
      if (placed != null) {
        placements.add(placed);
        _occupy(occupied, colTracks.length, placed);
        if (!colFixed && !rowFixed) {
          cursorRow = placed.rowStart;
          cursorCol = placed.colStart + placed.colSpan;
        }
      } else {
        placementDrops.add(GridDrop(id: item.id, reason: 'no-room'));
      }
    }

    // -- 2. Columns --------------------------------------------------------
    final colAxis = _sizeAxis(
        tracks: colTracks, span: spanX, placements: placements, rowAxis: false);

    // -- 3. Rows (aspect hints read the solved column extents) -------------
    double columnExtent(_Placement p) =>
        colAxis.edges[p.colStart + p.colSpan] - colAxis.edges[p.colStart];
    final rowAxis = _sizeAxis(
        tracks: rowTracks,
        span: spanY,
        placements: placements,
        rowAxis: true,
        crossExtent: columnExtent);

    // -- 4. Rects ----------------------------------------------------------
    final rects = <String, GridRect>{};
    final unitRects = <String, UnitRect>{};
    for (final p in placements) {
      final x0 = colAxis.edges[p.colStart];
      final x1 = colAxis.edges[p.colStart + p.colSpan];
      final y0 = rowAxis.edges[p.rowStart];
      final y1 = rowAxis.edges[p.rowStart + p.rowSpan];
      final col = metrics.snapColumn(x0);
      final width = metrics.snapColumn(x1) - col;
      final row = metrics.snapRow(y0);
      final height = metrics.snapRow(y1) - row;
      // Collapsed rects normalize to the canonical empty rect.
      rects[p.item.id] = width <= 0 || height <= 0
          ? GridRect.empty
          : GridRect(col: col, row: row, width: width, height: height);
      unitRects[p.item.id] =
          UnitRect(col: x0, row: y0, width: x1 - x0, height: y1 - y0);
    }

    return _SolvedGrid(
      rects: rects,
      unitRects: unitRects,
      columnSizes: colAxis.sizes,
      rowSizes: rowAxis.sizes,
      placementDrops: placementDrops,
      overflowX: colAxis.overflow,
      overflowY: rowAxis.overflow,
      trailingGapX: colAxis.trailingGap,
      trailingGapY: rowAxis.trailingGap,
    );
  }

  static void _occupy(Set<int> occupied, int trackCols, _Placement p) {
    for (var r = p.rowStart; r < p.rowStart + p.rowSpan; r++) {
      for (var c = p.colStart; c < p.colStart + p.colSpan; c++) {
        occupied.add(r * trackCols + c);
      }
    }
  }

  static bool _fits(
      Set<int> occupied, int trackCols, int c, int colSpan, int r, int rowSpan) {
    for (var rr = r; rr < r + rowSpan; rr++) {
      for (var cc = c; cc < c + colSpan; cc++) {
        if (occupied.contains(rr * trackCols + cc)) return false;
      }
    }
    return true;
  }

  /// Sizes one axis. See the pass description on [GridSolver].
  static _AxisResult _sizeAxis(
      {required List<GridTrack> tracks,
      required double span,
      required List<_Placement> placements,
      required bool rowAxis,
      double Function(_Placement p)? crossExtent}) {
    final n = tracks.length;
    final sizes = List<double>.filled(n, 0.0);
    final effMin = List<double>.filled(n, 0.0);

    // Effective minimums: track floors raised by single-span item content
    // minimums (clamped to the item's own max).
    for (var i = 0; i < n; i++) {
      effMin[i] = tracks[i].minUnits;
    }
    for (final p in placements) {
      final (start, count) =
          rowAxis ? (p.rowStart, p.rowSpan) : (p.colStart, p.colSpan);
      if (count != 1) continue;
      final item = p.item;
      var min = rowAxis ? item.minHeightUnits : item.minWidthUnits;
      if (min < 0) min = 0;
      final max = rowAxis ? item.maxHeightUnits : item.maxWidthUnits;
      if (max != null && min > max) min = max;
      if (min > effMin[start]) effMin[start] = min;
    }

    // Fixed tracks: size clamped to [effMin, max].
    for (var i = 0; i < n; i++) {
      final t = tracks[i];
      if (t.kind == TrackKind.fixed) {
        var s = t.sizeUnits < 0 ? 0.0 : t.sizeUnits;
        if (s > t.maxUnits) s = t.maxUnits;
        if (s < effMin[i]) s = effMin[i];
        sizes[i] = s;
      }
    }

    // Auto tracks: content minimums, then aspect hints (row axis, from the
    // solved cross extent), then spanning-item minimums spread over the
    // covered auto tracks.
    for (var i = 0; i < n; i++) {
      if (tracks[i].kind == TrackKind.auto) sizes[i] = effMin[i];
    }
    if (rowAxis && crossExtent != null) {
      for (final p in placements) {
        final hint = p.item.aspectHint;
        if (hint == null || hint <= 0 || p.rowSpan != 1) continue;
        final track = tracks[p.rowStart];
        if (track.kind != TrackKind.auto) continue;
        var desired = crossExtent(p) / hint;
        if (desired < effMin[p.rowStart]) desired = effMin[p.rowStart];
        final itemCap = p.item.maxHeightUnits ?? track.maxUnits;
        final cap = track.maxUnits < itemCap ? track.maxUnits : itemCap;
        if (desired > cap) desired = cap;
        if (desired > sizes[p.rowStart]) sizes[p.rowStart] = desired;
      }
    }
    for (final p in placements) {
      final (start, count) =
          rowAxis ? (p.rowStart, p.rowSpan) : (p.colStart, p.colSpan);
      if (count == 1) continue;
      final item = p.item;
      var min = rowAxis ? item.minHeightUnits : item.minWidthUnits;
      if (min <= epsilon) continue;
      final max = rowAxis ? item.maxHeightUnits : item.maxWidthUnits;
      if (max != null && min > max) min = max;
      var covered = 0.0;
      final donors = <int>[];
      for (var i = start; i < start + count; i++) {
        covered += sizes[i];
        if (tracks[i].kind == TrackKind.auto) donors.add(i);
      }
      final need = min - covered;
      if (need > epsilon && donors.isNotEmpty) {
        _spread(sizes, donors, need);
        for (final i in donors) {
          if (sizes[i] > tracks[i].maxUnits) sizes[i] = tracks[i].maxUnits;
        }
      }
    }
    for (var i = 0; i < n; i++) {
      if (tracks[i].kind == TrackKind.auto && sizes[i] > tracks[i].maxUnits) {
        sizes[i] = tracks[i].maxUnits;
      }
    }

    // Weighted tracks: share what is left, clamped to [effMin, max].
    final weighted = <int>[
      for (var i = 0; i < n; i++)
        if (tracks[i].kind == TrackKind.weighted) i
    ];
    if (weighted.isNotEmpty) {
      var used = 0.0;
      for (var i = 0; i < n; i++) {
        if (tracks[i].kind != TrackKind.weighted) used += sizes[i];
      }
      final room = span - used;
      var weightSum = 0.0;
      for (final i in weighted) {
        if (tracks[i].weight > 0) weightSum += tracks[i].weight;
      }
      if (weightSum > epsilon && room > epsilon) {
        final floors = <int, double>{};
        final fracs = <int, double>{};
        var floorSum = 0.0;
        for (final i in weighted) {
          final ideal = room * tracks[i].weight / weightSum;
          final floor = ideal.floorToDouble();
          floors[i] = floor;
          fracs[i] = ideal - floor;
          floorSum += floor;
        }
        var extras = (room - floorSum).round();
        // Whole units to the largest fractional remainder; ties to the
        // earlier track. extras < weighted.length for sane inputs; the
        // cycle is a safety net.
        final byFrac = [...weighted]..sort((a, b) {
            final d = fracs[b]!.compareTo(fracs[a]!);
            return d != 0 ? d : a.compareTo(b);
          });
        var k = 0;
        while (extras > 0) {
          floors[byFrac[k % byFrac.length]] = floors[byFrac[k % byFrac.length]]! + 1;
          extras--;
          k++;
        }
        for (final i in weighted) {
          sizes[i] = floors[i]!;
        }
      } else {
        for (final i in weighted) {
          sizes[i] = effMin[i];
        }
      }
      _reconcileWeightedClamps(tracks, sizes, effMin, weighted);
    }

    // Reconciliation: shrink back toward minimums if the axis overruns,
    // then report the residue.
    var total = 0.0;
    for (final s in sizes) {
      total += s;
    }
    var overflow = 0.0;
    var trailingGap = 0.0;
    final deficit = total - span;
    if (deficit > epsilon) {
      _shrinkTowardMins(sizes, tracks, effMin, deficit);
      total = 0.0;
      for (final s in sizes) {
        total += s;
      }
      final still = total - span;
      if (still > epsilon) {
        overflow = still;
        // Hard truncate from the far edge so edges never pass the span.
        var over = still;
        for (var i = n - 1; i >= 0 && over > epsilon; i--) {
          final take = sizes[i] < over ? sizes[i] : over;
          sizes[i] -= take;
          over -= take;
        }
        total -= still - over;
      }
      if (span - total > epsilon) trailingGap = span - total;
    } else if (deficit < -epsilon) {
      trailingGap = -deficit;
    }

    // A minimum that could not be honored (donors ran dry, tracks
    // truncated) is overflow too: it fuels the item-drop policy even when
    // the axis total exactly matches the span.
    var unmet = 0.0;
    for (var i = 0; i < n; i++) {
      final gap = effMin[i] - sizes[i];
      if (gap > epsilon) unmet += gap;
    }
    if (unmet > overflow) overflow = unmet;

    final edges = <double>[0.0];
    for (var i = 0; i < n; i++) {
      edges.add(edges[i] + sizes[i]);
    }
    return _AxisResult(sizes, edges, overflow, trailingGap);
  }

  /// Clamp pass for weighted tracks: raise any track below its effective
  /// minimum by taking from the largest-surplus track (ties: the later
  /// track donates); lower any track above its maximum by giving the excess
  /// to the smallest track with headroom (ties: the earlier track).
  static void _reconcileWeightedClamps(List<GridTrack> tracks,
      List<double> sizes, List<double> effMin, List<int> weighted) {
    for (var guard = 0; guard < tracks.length * 2 + 2; guard++) {
      var changed = false;

      // Raises.
      for (final i in weighted) {
        final need = effMin[i] - sizes[i];
        if (need <= epsilon) continue;
        var donor = -1;
        var donorSurplus = 0.0;
        for (final j in weighted) {
          if (j == i) continue;
          final surplus = sizes[j] - effMin[j];
          if (surplus <= epsilon) continue;
          final beats = surplus > donorSurplus + epsilon;
          final tiesLater = (surplus - donorSurplus).abs() <= epsilon &&
              j > donor &&
              donor >= 0;
          final firstDonor = donor < 0;
          if (beats || tiesLater || firstDonor) {
            donor = j;
            donorSurplus = surplus;
          }
        }
        if (donor < 0) continue;
        final move = need < donorSurplus ? need : donorSurplus;
        sizes[i] += move;
        sizes[donor] -= move;
        changed = true;
      }

      // Lowers.
      for (final i in weighted) {
        final excess = sizes[i] - tracks[i].maxUnits;
        if (excess <= epsilon) continue;
        sizes[i] = tracks[i].maxUnits;
        var give = excess;
        while (give > epsilon) {
          var receiver = -1;
          for (final j in weighted) {
            if (j == i) continue;
            if (sizes[j] >= tracks[j].maxUnits - epsilon) continue;
            if (receiver < 0 || sizes[j] < sizes[receiver] - epsilon) {
              receiver = j;
            }
          }
          if (receiver < 0) break;
          final headroom = tracks[receiver].maxUnits - sizes[receiver];
          final move = give < headroom ? give : headroom;
          sizes[receiver] += move;
          give -= move;
        }
        changed = true;
      }

      if (!changed) break;
    }
  }

  /// Shrink auto tracks (then weighted tracks) toward their effective
  /// minimums, largest surplus first (ties: the earlier track).
  static void _shrinkTowardMins(List<double> sizes, List<GridTrack> tracks,
      List<double> effMin, double deficit) {
    var remaining = deficit;
    for (final kind in [TrackKind.auto, TrackKind.weighted]) {
      while (remaining > epsilon) {
        var donor = -1;
        var donorSurplus = 0.0;
        for (var i = 0; i < tracks.length; i++) {
          if (tracks[i].kind != kind) continue;
          final surplus = sizes[i] - effMin[i];
          if (surplus > epsilon && surplus > donorSurplus) {
            donor = i;
            donorSurplus = surplus;
          }
        }
        if (donor < 0) break;
        final take = donorSurplus < remaining ? donorSurplus : remaining;
        sizes[donor] -= take;
        remaining -= take;
      }
      if (remaining <= epsilon) break;
    }
  }

  /// Spread [need] units over [donors] as evenly as whole units allow
  /// (extras to the earliest tracks); any fractional residue lands on the
  /// first donor. Deterministic.
  static void _spread(List<double> sizes, List<int> donors, double need) {
    final base = (need / donors.length).floorToDouble();
    for (final i in donors) {
      sizes[i] += base;
    }
    var left = need - base * donors.length;
    var idx = 0;
    while (left >= 1 - epsilon && idx < donors.length) {
      sizes[donors[idx]] += 1;
      left -= 1;
      idx++;
    }
    if (left > epsilon) sizes[donors[0]] += left;
  }
}

final class _Placement {
  final GridItem item;
  final int colStart;
  final int colSpan;
  final int rowStart;
  final int rowSpan;

  _Placement(this.item, this.colStart, this.colSpan, this.rowStart,
      this.rowSpan);

  factory _Placement.explicit(
      GridItem item, List<GridTrack> colTracks, List<GridTrack> rowTracks) {
    final colSpan = item.column.span.clamp(1, colTracks.length);
    final rowSpan = item.row.span.clamp(1, rowTracks.length);
    final colStart =
        (item.column.start ?? 0).clamp(0, colTracks.length - colSpan);
    final rowStart =
        (item.row.start ?? 0).clamp(0, rowTracks.length - rowSpan);
    return _Placement(item, colStart, colSpan, rowStart, rowSpan);
  }
}

final class _AxisResult {
  final List<double> sizes;
  final List<double> edges;
  final double overflow;
  final double trailingGap;

  _AxisResult(this.sizes, this.edges, this.overflow, this.trailingGap);
}

final class _SolvedGrid {
  final Map<String, GridRect> rects;
  final Map<String, UnitRect> unitRects;
  final List<double> columnSizes;
  final List<double> rowSizes;
  final List<GridDrop> placementDrops;
  final double overflowX;
  final double overflowY;
  final double trailingGapX;
  final double trailingGapY;

  _SolvedGrid({
    required this.rects,
    required this.unitRects,
    required this.columnSizes,
    required this.rowSizes,
    required this.placementDrops,
    required this.overflowX,
    required this.overflowY,
    required this.trailingGapX,
    required this.trailingGapY,
  });

  factory _SolvedGrid.empty(int colTracks, int rowTracks,
      Map<String, GridRect> rects, Map<String, UnitRect> unitRects,
      List<GridDrop> placementDrops) {
    return _SolvedGrid(
      rects: rects,
      unitRects: unitRects,
      columnSizes: List.filled(colTracks, 0.0),
      rowSizes: List.filled(rowTracks, 0.0),
      placementDrops: placementDrops,
      overflowX: 0,
      overflowY: 0,
      trailingGapX: 0,
      trailingGapY: 0,
    );
  }
}

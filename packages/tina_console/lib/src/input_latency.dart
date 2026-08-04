import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'input_event.dart';

/// Nanosecond timestamp for stage stamps. Uses [DateTime] (always available
/// and monotonic within a run) rather than the FFI CLOCK_MONOTONIC binding,
/// which returns 0 in some environments. All stages share this one clock so
/// inter-stage deltas are valid. Microsecond-granular, sufficient for
/// per-stage input-latency deltas (sub-µs work isn't measurable here anyway).
int _nowNanos() => DateTime.now().microsecondsSinceEpoch * 1000;

/// Per-stage markers along the native-dequeue → synchronous-flush path.
///
/// Stage 0 ([nativeDequeued]) carries the timestamp produced by the native
/// input pump; the rest are stamped by Dart code as the event travels through
/// the backend, editor, render frame, and backend flush.
enum LatencyStage {
  nativeDequeued,
  dartDelivered,
  handlerEntered,
  bufferMutated,
  renderStarted,
  flushCompleted,
}

/// Coarse classification so paste and navigation bursts don't distort the
/// character-latency percentiles that the optimization targets care about.
enum InputKind { character, paste, navigation }

InputKind _kindOf(InputEvent e) =>
    e is CharInput ? InputKind.character : e is PasteInput ? InputKind.paste : InputKind.navigation;

/// One event's progress through the [LatencyStage]s. Stamps are recorded in
/// monotonic-nanosecond units; null means the stage was never reached.
class _Trace {
  final InputKind kind;
  final List<int?> stamps = List.filled(LatencyStage.values.length, null);
  _Trace(this.kind);
  void stamp(LatencyStage s, int nanos) => stamps[s.index] = nanos;
}

/// Fixed-capacity ring of ints. Overwrites the oldest sample once full, so the
/// retained sample set stays bounded (no unbounded sample list). Exact-percentile
/// storage with O(1) append.
class _RingBuffer {
  final int capacity;
  final List<int> _buf;
  int _head = 0;
  int _count = 0;

  _RingBuffer(this.capacity) : _buf = List<int>.filled(capacity, 0);

  void add(int v) {
    _buf[_head] = v;
    _head = (_head + 1) % capacity;
    if (_count < capacity) _count++;
  }

  int get length => _count;

  /// Samples in insertion order.
  List<int> toOrdered() {
    final out = <int>[];
    for (var i = 0; i < _count; i++) {
      final idx = (_head - _count + i);
      out.add(_buf[idx < 0 ? idx + capacity : idx]);
    }
    return out;
  }
}

/// Per-kind store of the 5 inter-stage deltas plus the end-to-end total.
class _KindStore {
  // Series layout:
  //   0 nativeDequeued→dartDelivered
  //   1 dartDelivered→handlerEntered
  //   2 handlerEntered→bufferMutated
  //   3 bufferMutated→renderStarted
  //   4 renderStarted→flushCompleted
  //   5 end-to-end total
  final List<_RingBuffer> _series;

  _KindStore(int cap) : _series = List.generate(6, (_) => _RingBuffer(cap));

  void record(_Trace t) {
    final s = t.stamps;
    // Require every stage to be present; a partial trace can't yield clean
    // deltas (e.g. an event that never reached the editor).
    for (final stamp in s) {
      if (stamp == null) return;
    }
    var prev = s[0]!;
    for (var i = 1; i < s.length; i++) {
      final cur = s[i]!;
      _series[i - 1].add(cur - prev);
      prev = cur;
    }
    _series[5].add(prev - s[0]!);
  }

  List<int> series(int i) => _series[i].toOrdered();
  int seriesCount(int i) => _series[i].length;
}

const int kSampleCap = 4096;

/// Operation counters captured alongside latency traces. All increments are
/// gated behind [InputLatency.enabled] so they add zero overhead when tracing
/// is off. Counts are approximate (not fenced by a frame transaction) but
/// bounded and reset together with the latency samples.
class OpCounters {
  static final OpCounters instance = OpCounters._();

  static bool get enabled => InputLatency.enabled;

  int gridWrites = 0;
  int erasedCells = 0;
  int styleChanges = 0;
  // Phase 4: styled-run parse cache. A miss parses the string into runs; a hit
  // reuses a cached run list. Proves the cache avoids re-parsing repainted rows.
  int styleParseHits = 0;
  int styleParseMisses = 0;
  // Phase 4: number of times the styled-run emitter ran (one per SGR-bearing
  // string emitted). Stays flat per distinct styled row per frame.
  int styledRunEmits = 0;
  int borderRepairs = 0;
  int logicalFrames = 0;
  int renderCalls = 0;
  int refreshCalls = 0;
  int childSurfaceRequests = 0;
  int chatRowsEmitted = 0;
  int nativeEvents = 0;
  int dartCallbackBatches = 0;

  OpCounters._();

  Map<String, int> snapshot() => {
        'gridWrites': gridWrites,
        'erasedCells': erasedCells,
        'styleChanges': styleChanges,
        'styleParseHits': styleParseHits,
        'styleParseMisses': styleParseMisses,
        'styledRunEmits': styledRunEmits,
        'borderRepairs': borderRepairs,
        'logicalFrames': logicalFrames,
        'renderCalls': renderCalls,
        'refreshCalls': refreshCalls,
        'childSurfaceRequests': childSurfaceRequests,
        'chatRowsEmitted': chatRowsEmitted,
        'nativeEvents': nativeEvents,
        'dartCallbackBatches': dartCallbackBatches,
      };

  void reset() {
    gridWrites = erasedCells = styleChanges = borderRepairs = 0;
    styleParseHits = styleParseMisses = styledRunEmits = 0;
    logicalFrames = renderCalls = refreshCalls = childSurfaceRequests = 0;
    chatRowsEmitted = nativeEvents = dartCallbackBatches = 0;
  }
}

/// Opt-in native-dequeue through synchronous redraw/flush latency recorder.
///
/// Enable with `COCOON_DEBUG_INPUT_LATENCY=1`. All entry points are no-ops
/// when disabled, so production throughput is unaffected. Each delivered input
/// event gets a [_Trace] keyed by the event object; [_active] is the trace of
/// the event currently being handled synchronously by the editor, so stages
/// stamped without an event in scope (render, flush) can find their trace.
abstract final class InputLatency {
  static bool _forced = false;
  static bool get enabled =>
      _forced || Platform.environment['COCOON_DEBUG_INPUT_LATENCY'] == '1';

  /// Test-only escape hatch so unit tests can enable tracing without spawning a
  /// process with the env var set.
  /// Force-enable tracing from code (used by the benchmark harness, which
  /// can't set an env var before its own process starts). The env var path
  /// ([Platform.environment] read above) still applies for production runs.
  static void forceEnable() => _forced = true;

  static final Expando<_Trace> _traces = Expando<_Trace>('inputTraces');
  static _Trace? _active;

  static final Map<InputKind, _KindStore> _stores = {
    for (final k in InputKind.values) k: _KindStore(kSampleCap),
  };

  /// Begin a trace for [event] at native-dequeue time. [nativeNanos] is the
  /// timestamp produced by the native input pump; pass a Dart clock value for
  /// backends without a native pump (the nativeDequeued→dartDelivered delta is
  /// then meaningless but the trace stays internally consistent).
  static void begin(InputEvent event, int nativeNanos) {
    if (!enabled) return;
    final trace = _traces[event] ??= _Trace(_kindOf(event));
    trace.stamp(LatencyStage.nativeDequeued, nativeNanos);
    trace.stamp(LatencyStage.dartDelivered, _nowNanos());
  }

  /// Begin a trace only if one isn't already present (e.g. for paste/navigation
  /// events emitted without a native-dequeue mark).
  static void beginIfAbsent(InputEvent event) {
    if (!enabled) return;
    if (_traces[event] != null) return;
    begin(event, _nowNanos());
  }

  /// The trace for [event], if one is in flight.
  static _Trace? traceOf(InputEvent event) => _traces[event];

  /// Test-only: record a fully-formed trace with explicit monotonic [stamps]
  /// (one per [LatencyStage], in order), bypassing the live timing capture.
  /// Lets unit tests assert percentile math on known distributions.
  @visibleForTesting
  static void recordTrace(InputKind kind, List<int> stamps) {
    assert(stamps.length == LatencyStage.values.length);
    final t = _Trace(kind);
    for (var i = 0; i < stamps.length; i++) {
      t.stamp(LatencyStage.values[i], stamps[i]);
    }
    _stores[kind]!.record(t);
  }

  /// Mark the editor's synchronous handling of [event] as started: stamp
  /// the [LatencyStage.handlerEntered] stage and activate the trace so later
  /// [stage] marks (render/flush) can find it.
  static void handlerEntered(InputEvent event) {
    if (!enabled) return;
    final trace = _traces[event];
    if (trace == null) return;
    trace.stamp(LatencyStage.handlerEntered, _nowNanos());
    _active = trace;
  }

  /// Stamp the named [stage] on the currently-handled trace (no event in
  /// scope). A no-op when nothing is being handled (e.g. animation/resize
  /// redraws that aren't driven by input).
  static void stage(LatencyStage stage) {
    if (!enabled) return;
    _active?.stamp(stage, _nowNanos());
  }

  /// Finalize the trace for [event]: fold its deltas into the per-kind store
  /// and deactivate.
  static void complete(InputEvent event) {
    if (!enabled) return;
    final trace = _traces[event];
    if (trace == null) return;
    _stores[trace.kind]!.record(trace);
    if (identical(_active, trace)) _active = null;
  }

  /// Percentiles for one delta/total series of one kind, in milliseconds.
  static _SeriesStats _stats(InputKind kind, int series) {
    final samples = _stores[kind]!.series(series);
    if (samples.isEmpty) {
      return const _SeriesStats(count: 0, p50: 0, p95: 0, p99: 0, max: 0);
    }
    final sorted = [...samples]..sort();
    double p(double q) => sorted[((sorted.length - 1) * q).round()] / 1e6;
    return _SeriesStats(
      count: sorted.length,
      p50: p(.50),
      p95: p(.95),
      p99: p(.99),
      max: sorted.last / 1e6,
    );
  }

  /// Machine-readable report: per-kind, per-stage delta stats plus the
  /// end-to-end total, with counters merged in.
  static InputLatencyReport report() {
    final kinds = <String, dynamic>{};
    for (final kind in InputKind.values) {
      final seriesOut = <String, dynamic>{};
      for (var i = 0; i < 6; i++) {
        seriesOut[_seriesName(i)] = _stats(kind, i).toJson();
      }
      kinds[kind.name] = seriesOut;
    }
    return InputLatencyReport(kinds: kinds, counters: OpCounters.instance.snapshot());
  }

  static String _seriesName(int i) => const [
        'native_dequeued_to_dart',
        'dart_to_handler',
        'handler_to_buffer',
        'buffer_to_render',
        'render_to_flush',
        'end_to_end',
      ][i];

  /// Compatibility shim: overall end-to-end percentiles across all kinds,
  /// matching the shape the editor's [close] print expects.
  static InputLatencySnapshot snapshot() {
    final all = <int>[];
    for (final kind in InputKind.values) {
      all.addAll(_stores[kind]!.series(5));
    }
    if (all.isEmpty) {
      return const InputLatencySnapshot(
        count: 0,
        p50Millis: 0,
        p95Millis: 0,
        p99Millis: 0,
        maxMillis: 0,
      );
    }
    final sorted = [...all]..sort();
    double p(double q) => sorted[((sorted.length - 1) * q).round()] / 1e6;
    return InputLatencySnapshot(
      count: sorted.length,
      p50Millis: p(.50),
      p95Millis: p(.95),
      p99Millis: p(.99),
      maxMillis: sorted.last / 1e6,
    );
  }

  /// Reset all retained samples and counters.
  static void reset() {
    for (final kind in InputKind.values) {
      _stores[kind] = _KindStore(kSampleCap);
    }
    OpCounters.instance.reset();
    _active = null;
  }
}

class _SeriesStats {
  final int count;
  final double p50;
  final double p95;
  final double p99;
  final double max;
  const _SeriesStats({
    required this.count,
    required this.p50,
    required this.p95,
    required this.p99,
    required this.max,
  });
  Map<String, dynamic> toJson() => {
        'count': count,
        'p50_ms': p50,
        'p95_ms': p95,
        'p99_ms': p99,
        'max_ms': max,
      };
}

/// Percentiles over the flat end-to-end sample set (kept for the editor's
/// [close] summary print).
class InputLatencySnapshot {
  final int count;
  final double p50Millis;
  final double p95Millis;
  final double p99Millis;
  final double maxMillis;

  const InputLatencySnapshot({
    required this.count,
    required this.p50Millis,
    required this.p95Millis,
    required this.p99Millis,
    required this.maxMillis,
  });
}

/// Full structured report (per-kind stage stats + operation counters).
class InputLatencyReport {
  final Map<String, dynamic> kinds;
  final Map<String, int> counters;
  InputLatencyReport({required this.kinds, required this.counters});

  Map<String, dynamic> toJson() => {'kinds': kinds, 'counters': counters};

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}

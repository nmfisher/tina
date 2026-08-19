import 'dart:async';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../input_event.dart';
import '../input_latency.dart';
import '../paste_audit.dart';
import 'input_backend.dart';
import 'paste_burst_detector.dart';
import 'reply_sequence_filter.dart';

final _log = Logger('tina_console.notcurses_input');

/// A single key event as returned by the notcurses input source. Thin wrapper
/// so the live FFI path and test fakes share the same shape.
@visibleForTesting
class NcKeyEvent {
  final int id;
  final bool hasAlt;
  final bool hasCtrl;
  final bool isSynthesized;

  const NcKeyEvent(this.id, this.hasAlt, this.hasCtrl, this.isSynthesized);
}

/// Source of raw notcurses key events. Abstracted so
/// [NotcursesInputBackend] (and its startup drain) can be unit-tested without
/// a live libnotcurses.
abstract class KeySource {
  /// Return the next available key event, or `null` if none is ready.
  NcKeyEvent? poll();

  /// Release any native resources held by [key]. Live keys wrap an [nc.Key]
  /// that must be destroyed; fakes are no-ops.
  void disposeKey(NcKeyEvent key);
}

/// Live key source over a real [nc.NotCurses] context.
class _NotcursesKeySource implements KeySource {
  final nc.NotCurses _nc;

  _NotcursesKeySource(this._nc);

  @override
  NcKeyEvent? poll() {
    final result = _nc.getNonBlocking(keyInfo: true);
    if (result.value == null || result.result == 0) return null;
    final key = result.value!;
    final event = NcKeyEvent(
      key.id,
      key.hasAlt(),
      key.hasCtrl(),
      key.keySynthesizedP(),
    );
    // Destroy immediately; callers treat the returned event as plain data.
    key.destroy();
    return event;
  }

  @override
  void disposeKey(NcKeyEvent key) {
    // Already destroyed in [poll].
  }
}

/// Tracks the post-init startup drain window.
///
/// Right after notcurses init the terminal replies to capability queries
/// (DA2, XTVERSION, bracketed-paste echoes, etc.). Those replies land on
/// stdin and, if forwarded, leak into the editor as visible junk (";1c",
/// "200~"). The drain discards input during this window.
///
/// A fixed window is fragile: on a cold first run the terminal can take
/// longer than 150 ms to reply, while on a warm second run replies are fast
/// and the user may start typing immediately. This implementation uses an
/// adaptive window:
///
///  - always drain for at least [minWindow], to cover the normal fast case;
///  - if events keep arriving within [idleThreshold], extend the drain up to
///    [maxWindow];
///  - if the minimum window has passed and no event has been seen, stop
///    draining so keystrokes are not delayed.
@visibleForTesting
class StartupDrain {
  final Duration _minWindow;
  final Duration _maxWindow;
  final Duration _idleThreshold;
  final Stopwatch _clock;
  int? _lastEventMicros;

  StartupDrain({
    required Duration minWindow,
    required Duration maxWindow,
    required Duration idleThreshold,
    Stopwatch? clock,
  })  : _minWindow = minWindow,
        _maxWindow = maxWindow,
        _idleThreshold = idleThreshold,
        _clock = clock ?? (Stopwatch()..start());

  /// Whether the drain is still active.
  ///
  /// Always drains for [minWindow]. After that, stays open only while events
  /// keep arriving within [idleThreshold] of the last one (a slow reply
  /// burst), up to [maxWindow]. With no event seen at all past [minWindow],
  /// the drain closes immediately so a warm-start user's first keystroke is
  /// never eaten.
  bool get isDraining {
    final elapsed = _clock.elapsed;
    if (elapsed < _minWindow) return true;
    if (elapsed >= _maxWindow) return false;
    final last = _lastEventMicros;
    if (last == null) return false;
    return (_clock.elapsedMicroseconds - last) < _idleThreshold.inMicroseconds;
  }

  /// Record that an event was seen during the drain.
  void sawEvent() {
    _lastEventMicros = _clock.elapsedMicroseconds;
  }
}

/// Input backend that reads key events from the notcurses event loop and
/// translates them into [InputEvent]s.
///
/// Uses [nc.NotCurses.getNonBlocking] (via [_NotcursesKeySource]) to poll for
/// input events and maps [nc.NcKey] codes to the tina_console [InputEvent]
/// hierarchy.
class NotcursesInputBackend implements InputBackend {
  final KeySource _keySource;
  final _controller = StreamController<InputEvent>(sync: true);
  Timer? _pollTimer;
  Timer? _startupTimer;
  nc.NotcursesInputPump? _pump;
  StreamSubscription<nc.PumpedInput>? _pumpSub;
  Timer? _pasteIdleTimer;
  StringBuffer? _explicitPaste;
  // tin-v6tq: releases an ESC the reply filter is holding when no introducer
  // follows. Event-driven, so nothing else would ever deliver it.
  Timer? _replyEscTimer;
  // On the event-driven pump path there is no poll tick to call
  // PasteBurstDetector.expire() — a paste's final burst would sit buffered
  // until the next keystroke. This timer re-arms on each pending event and
  // flushes the burst joinWindow after it stops forming. Mirrors
  // _pasteIdleTimer (the explicit-marker path's 250ms idle flush), but at the
  // detector's joinWindow and via expire().
  Timer? _burstFlushTimer;
  bool _disposed = false;
  final Completer<void> _ready = Completer<void>();

  /// Adaptive drain that discards terminal capability-query replies which
  /// otherwise leak into the editor as visible junk. See [StartupDrain].
  late final StartupDrain _startupDrain;
  bool _startupDrainDone = false;

  /// Monotonic clock shared by the drain and the paste-burst detector.
  final Stopwatch _startupClock;

  /// Detects pastes as temporal bursts. notcurses swallows the bracketed-paste
  /// markers (`ESC[200~`/`ESC[201~`) entirely (confirmed by the
  /// dart_notcurses paste spike), so a paste arrives as a tight cluster of
  /// char events with ~15–30µs inter-event gaps — ~1000× tighter than typing.
  /// The detector joins events within [_burstDetector]'s window and, when the
  /// burst clears the char threshold, emits one [PasteInput] with newlines/tabs
  /// preserved (a pasted Enter becomes `\n` in the paste, not a submit). Null
  /// when burst detection is disabled (testing escape hatch).
  final PasteBurstDetector? _burstDetector;

  /// Drops terminal capability replies that survive past the [StartupDrain]
  /// window (tin-v6tq). notcurses has no rule for OSC/DCS/APC replies after
  /// init, so they surface as `ESC` + printable key events; without this
  /// filter the burst detector joins the printable tail into one `PasteInput`
  /// and ~4.5 KB of reply garbage lands in the editor. Applied to raw pump
  /// records ahead of the burst detector. Null when reply filtering is
  /// disabled (testing escape hatch).
  final ReplySequenceFilter? _replyFilter;

  /// Build a backend over [keySource]. Tests inject a fake; production uses
  /// [NotcursesInputBackend.fromNotcurses].
  NotcursesInputBackend(
    this._keySource, {
    Duration? startupDrainMinWindow,
    Duration? startupDrainMaxWindow,
    Duration? startupDrainIdleThreshold,
    PasteBurstDetector? burstDetector,
    Stopwatch? clock,
    bool startPolling = true,
    nc.NotcursesInputPump? pump,
    bool temporalPasteDetection = true,
    ReplySequenceFilter? replyFilter,
    bool replySequenceFiltering = true,
  })  : _startupClock = clock ?? Stopwatch(),
        _burstDetector = temporalPasteDetection
            ? (burstDetector ??
                PasteBurstDetector.audited(
                    onAudit: PasteAudit.enabled ? PasteAudit.log : null))
            : null,
        _replyFilter = replySequenceFiltering
            ? (replyFilter ?? ReplySequenceFilter())
            : null,
        _pump = pump {
    _startupDrain = StartupDrain(
      minWindow: startupDrainMinWindow ?? const Duration(milliseconds: 150),
      maxWindow: startupDrainMaxWindow ?? const Duration(seconds: 1),
      idleThreshold:
          startupDrainIdleThreshold ?? const Duration(milliseconds: 30),
      clock: _startupClock,
    );
    if (pump != null) {
      // Bind the batch boundary before subscribing, so the first drain's
      // records observe the per-batch counter + first-event-synchronous flag.
      // The native thread may fire a notification once _startPump subscribes;
      // _onBatchStart is safe to call now (all fields it touches are set).
      pump.onBatchStart = (n) => _onBatchStart(n);
      _startPump();
    } else if (startPolling) {
      _startPolling();
    }
  }

  /// Test hook to advance the polling loop deterministically without waiting
  /// for the real timer.
  @visibleForTesting
  void pollForTest() => _pollOnce();

  /// Feed a native-pump record without a live terminal. Each call is a
  /// single-record batch (the pre-Phase-6 per-event contract); use
  /// [pumpedBatchForTest] to exercise multi-record batching.
  @visibleForTesting
  void pumpedInputForTest(int id, {int modifiers = 0}) {
    _onBatchStart();
    _onPumpedInput(nc.PumpedInput(id, modifiers, _nowMicros * 1000));
  }

  /// Feed a batch of native-pump records without a live terminal, mirroring
  /// what one pump drain call delivers. Increments [OpCounters.dartCallbackBatches]
  /// once for the whole batch and [OpCounters.nativeEvents] per record, then
  /// routes each record through [_onPumpedInput]. The first record of the batch
  /// is synchronous via [_emit]; the rest defer.
  @visibleForTesting
  void pumpedBatchForTest(List<nc.PumpedInput> batch) {
    if (batch.isEmpty) return;
    _onBatchStart();
    for (final input in batch) {
      _onPumpedInput(input);
    }
  }

  /// Per-batch bookkeeping: one native→Dart notification = one batch. Counts
  /// [OpCounters.dartCallbackBatches] once and arms the first-event-synchronous
  /// flag so the first record of the batch emits synchronously and the rest
  /// defer via [_emit]'s microtask path.
  void _onBatchStart([int recordCount = 0]) {
    if (_disposed) return;
    if (OpCounters.enabled) {
      OpCounters.instance.dartCallbackBatches++;
    }
    // tin-w8dl: batch cadence is the delivery-stall signal. A >30ms hole
    // between consecutive batch lines mid-paste means the Dart event loop
    // stalled between native drains — exactly the lie that splits one paste
    // into detector "bursts" (the detector stamps arrival with delivery time).
    if (PasteAudit.enabled && recordCount > 0) {
      PasteAudit.log('batch n=$recordCount');
    }
    _firstThisTick = true;
  }

  /// Convenience factory that wraps a live [nc.NotCurses] context.
  factory NotcursesInputBackend.fromNotcurses(
    nc.NotCurses nc, {
    Duration? startupDrainMinWindow,
    Duration? startupDrainMaxWindow,
    Duration? startupDrainIdleThreshold,
    PasteBurstDetector? burstDetector,
    Stopwatch? clock,
  }) {
    final pump = nc.startInputPump();
    return NotcursesInputBackend(
      _NotcursesKeySource(nc),
      startupDrainMinWindow: startupDrainMinWindow,
      startupDrainMaxWindow: startupDrainMaxWindow,
      startupDrainIdleThreshold: startupDrainIdleThreshold,
      burstDetector: burstDetector,
      startPolling: false,
      pump: pump,
      // The live notcurses path uses temporal burst detection. The explicit
      // NcKey.pasteBegin/pasteEnd marker path (below in _onPumpedInput) is
      // dormant: the vendored notcurses paste-events patch is compiled in, but
      // the markers do not arrive through the pump in practice (verified via
      // tool/paste_batch_spike.dart), so the marker branches never engage.
      // Temporal detection is the path that actually works; keep the marker
      // machinery as a forward path for if/when markers emit reliably.
      temporalPasteDetection: true,
      clock: clock,
    );
  }

  @override
  Stream<InputEvent> get events => _controller.stream;

  @override
  Future<void> get ready => _ready.future;

  void _startPump() {
    _startupClock.start();
    _pumpSub = _pump!.events.listen(_onPumpedInput);
    _scheduleStartupCheck();
  }

  void _scheduleStartupCheck() {
    _startupTimer?.cancel();
    _startupTimer = Timer(const Duration(milliseconds: 10), () {
      if (_disposed || _startupDrainDone) return;
      if (_startupDrain.isDraining) {
        _scheduleStartupCheck();
        return;
      }
      _onDrainEnd();
    });
  }

  /// Close the startup drain. If the reply filter is holding a lone `ESC` —
  /// armed by a record the drain already discarded — that ESC must be dropped,
  /// not kept: releasing it after the boundary would replay a stale Escape in
  /// front of the next real keystroke. Mid-reply state survives on purpose;
  /// that is the boundary-split swallow (tin-k7tr).
  void _onDrainEnd() {
    _startupDrainDone = true;
    final filter = _replyFilter;
    if (filter != null && filter.isHoldingEscape) {
      filter.flush(); // Discard: [_esc], already consumed by the drain.
    }
    if (!_ready.isCompleted) _ready.complete();
  }

  void _onPumpedInput(nc.PumpedInput input) {
    if (_disposed) return;
    if (OpCounters.enabled) {
      OpCounters.instance.nativeEvents++;
    }
    if (!_startupDrainDone && _startupDrain.isDraining) {
      _startupDrain.sawEvent();
      // tin-k7tr: the drain discards this record, but the reply filter must
      // still see it. A reply sequence can straddle the drain boundary — its
      // ESC + introducer drained, its tail arriving after — and a filter left
      // idle at the boundary passes that tail through as ordinary typing
      // (observed on --resume: `;154;rgb:afff/ffff/ff00` pasted into the
      // editor, prefixing real input). Feeding the filter here keeps its
      // sequence state continuous across the boundary so the post-drain tail
      // is swallowed; the filter's released output is discarded with the
      // record. (_explicitPaste is provably null here: it is only set in
      // _deliverPumpedKey, which the drain never reaches.)
      _replyFilter?.add(input.id, input.monotonicNanos ~/ 1000);
      return;
    }
    if (!_startupDrainDone) {
      _onDrainEnd();
    }
    // tin-v6tq: a terminal capability reply that arrives past the drain
    // window surfaces as ESC + printable key events (notcurses has no rule
    // for OSC/DCS/APC replies after init). Run the raw ids through the reply
    // filter BEFORE the paste-burst detector, which would otherwise join the
    // printable tail into one PasteInput and paste ~4.5 KB of reply garbage
    // into the editor. Bypassed inside an explicit marker-delimited paste:
    // that content is known-genuine.
    final filter = _replyFilter;
    if (filter == null || _explicitPaste != null) {
      _deliverPumpedKey(input.id, input.modifiers, input.monotonicNanos);
      return;
    }
    final released = filter.add(input.id, input.monotonicNanos ~/ 1000);
    for (final id in released) {
      _deliverPumpedKey(id, input.modifiers, input.monotonicNanos);
    }
    if (filter.isHoldingEscape) {
      _armReplyEscTimer();
    }
  }

  /// Translate and route one (possibly filter-released) pump record id.
  void _deliverPumpedKey(int id, int modifiers, int monotonicNanos) {
    if (id == nc.NcKey.pasteBegin) {
      _finishExplicitPaste();
      _explicitPaste = StringBuffer();
      _armPasteIdleTimer();
      return;
    }
    if (id == nc.NcKey.pasteEnd) {
      _finishExplicitPaste();
      return;
    }
    final event = _translateKey(NcKeyEvent(
      id,
      (modifiers & nc.KeyMod.alt) != 0,
      (modifiers & nc.KeyMod.ctrl) != 0,
      id >= nc.preterunicode(0) && id <= nc.NcKey.eof,
    ));
    if (event == null) {
      if (PasteAudit.enabled) {
        PasteAudit.log('pump path: untranslated drop id=$id');
      }
      return;
    }
    final paste = _explicitPaste;
    if (paste != null) {
      switch (event) {
        case CharInput(:final text):
          paste.write(text);
        case ControlKey(:final code) when code == ControlCode.enter:
          paste.write('\n');
        case ControlKey(:final code) when code == ControlCode.tab:
          paste.write('\t');
        default:
          break;
      }
      _armPasteIdleTimer();
      return;
    }
    InputLatency.begin(event, monotonicNanos);
    _handleEvent(event);
  }

  /// Arm the release for an ESC the reply filter is holding. A genuine lone
  /// ESC (cancel) must not wait for the next keystroke to be delivered — on
  /// an event-driven path there may never be one.
  void _armReplyEscTimer() {
    _replyEscTimer?.cancel();
    final filter = _replyFilter!;
    _replyEscTimer = Timer(
      filter.introducerWindow + const Duration(milliseconds: 1),
      _releaseHeldEscape,
    );
  }

  /// Release an ESC still held by the reply filter once no introducer arrived
  /// inside the window: it was a real Escape, not a reply opener.
  void _releaseHeldEscape() {
    _replyEscTimer = null;
    final filter = _replyFilter;
    if (filter == null || _disposed || !filter.isHoldingEscape) return;
    // Its own "tick": the release is timer-driven, so emit synchronously like
    // _flushBurst does, then let later events defer.
    _firstThisTick = true;
    for (final id in filter.flush()) {
      _deliverPumpedKey(id, 0, _nowMicros * 1000);
    }
  }

  void _armPasteIdleTimer() {
    _pasteIdleTimer?.cancel();
    _pasteIdleTimer = Timer(
      const Duration(milliseconds: 250),
      _finishExplicitPaste,
    );
  }

  void _finishExplicitPaste() {
    _pasteIdleTimer?.cancel();
    _pasteIdleTimer = null;
    final paste = _explicitPaste;
    _explicitPaste = null;
    if (paste != null) _emit(PasteInput(paste.toString()));
  }

  void _startPolling() {
    // Poll at ~60Hz (16ms). Notcurses's getInputReadyFD() returns a file
    // descriptor that can be polled, but Dart doesn't expose poll() directly.
    // A Timer-based loop is a reasonable fallback.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_disposed) return;
      _pollOnce();
    });
  }

  void _pollOnce() {
    // Start the drain clock on the first poll. The Stopwatch is constructed
    // unstarted in [NotcursesInputBackend]; this defers the drain window to
    // when polling actually begins, so a slow cold-start JIT (which delays
    // the first timer fire) doesn't let the whole 150 ms window elapse
    // before any reply is even read.
    if (!_startupClock.isRunning && !_startupDrainDone) {
      _startupClock.start();
    }
    final draining = !_startupDrainDone && _startupDrain.isDraining;
    _firstThisTick = true;
    var drainedCount = 0;
    while (true) {
      final key = _keySource.poll();
      if (key == null) break;
      if (!draining) {
        final event = _translateKey(key);
        if (event != null) {
          _handleEvent(event);
        } else if (PasteAudit.enabled) {
          PasteAudit.log('poll path: untranslated drop id=${key.id}');
        }
      } else {
        drainedCount++;
        _startupDrain.sawEvent();
        _log.fine(() => 'startup drain discarded key id=${key.id}');
      }
      _keySource.disposeKey(key);
    }
    if (drainedCount > 0) {
      _log.fine('startup drain discarded $drainedCount keys this tick');
    }

    // A poll tick with no new events still gets a chance to expire a burst
    // that stopped forming: a paste's last event arrives, then typing pauses
    // for >joinWindow, and without this the paste would sit buffered until the
    // next keypress. expire() is a no-op when nothing is pending.
    if (!draining) {
      final expired = _burstDetector?.expire(_nowMicros);
      if (expired != null) {
        for (final e in expired) {
          _emit(e);
        }
      }
    }

    // Close the drain once its window has ended so subsequent events flow
    // through normally.
    if (!_startupDrainDone && !_startupDrain.isDraining) {
      _onDrainEnd();
      _log.fine('startup drain complete');
    }
  }

  /// Feed one translated event through the burst detector (or emit directly
  /// when burst detection is disabled). The detector buffers events into a
  /// burst and returns the events to emit now — usually empty (the burst is
  /// still forming) unless this event's gap from the previous one exceeded the
  /// join window, in which case the previous burst is flushed first.
  void _handleEvent(InputEvent event) {
    final detector = _burstDetector;
    if (detector == null) {
      _emit(event);
      return;
    }
    final emitted = detector.add(event, _nowMicros);
    for (final e in emitted) {
      _emit(e);
    }
    // On the pump path there is no poll tick to expire a burst that stopped
    // forming. Re-arm a short timer so the final flush lands just past
    // joinWindow after the last event — otherwise a paste sits buffered until
    // the next keystroke. +1ms: PasteBurstDetector.expire() uses a strict `>`
    // gap check, so a timer armed at exactly joinWindow could fire with the gap
    // == joinWindow (== is not >) and fail to flush.
    if (detector.hasPending) {
      _armBurstFlushTimer(detector.joinWindow + const Duration(milliseconds: 1));
    }
  }

  void _armBurstFlushTimer(Duration window) {
    _burstFlushTimer?.cancel();
    _burstFlushTimer = Timer(window, _flushBurst);
  }

  /// Flush any burst that stopped forming. Fires joinWindow after the last
  /// pending event on the pump path (the polling path expires in _pollOnce).
  void _flushBurst() {
    _burstFlushTimer?.cancel();
    _burstFlushTimer = null;
    final detector = _burstDetector;
    if (detector == null) return;
    if (PasteAudit.enabled) {
      PasteAudit.log('flush-timer fired (joinWindow after last pending)');
    }
    final expired = detector.expire(_nowMicros);
    if (expired.isEmpty) return;
    // A flush from a Timer callback is its own "tick": emit the first
    // synchronously and the rest via microtask, matching _emit's per-batch
    // contract so readKey can re-arm between events.
    _firstThisTick = true;
    for (final e in expired) {
      _emit(e);
    }
  }

  /// Emit one event, deferring all but the first per tick so readKey has a
  /// chance to re-arm _keyCompleter between events (the stream consumer is
  /// single-shot per key). The first event of a tick goes synchronously.
  void _emit(InputEvent event) {
    InputLatency.beginIfAbsent(event);
    if (_firstThisTick) {
      _firstThisTick = false;
      _controller.add(event);
    } else {
      scheduleMicrotask(() => _controller.add(event));
    }
  }

  bool _firstThisTick = true;
  int get _nowMicros => _startupClock.elapsedMicroseconds;

  /// Translate a notcurses key event to a tina_console [InputEvent].
  InputEvent? _translateKey(NcKeyEvent key) => translateNcKey(
        id: key.id,
        hasAlt: key.hasAlt,
        hasCtrl: key.hasCtrl,
        isSynthesized: key.isSynthesized,
      );

  @override
  void inject(InputEvent event) {
    if (_disposed) return;
    _controller.add(event);
  }

  /// Stop polling and close the event stream. Idempotent.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    _burstFlushTimer?.cancel();
    _burstFlushTimer = null;
    _replyEscTimer?.cancel();
    _replyEscTimer = null;
    _finishExplicitPaste();
    _pumpSub?.cancel();
    _pumpSub = null;
    _pump?.stop();
    _pump = null;
    if (!_ready.isCompleted) _ready.complete();
    // Flush any burst still buffered (e.g. a paste whose final event arrived
    // but whose join window hadn't elapsed) before closing the stream, so it
    // isn't dropped.
    final pending = _burstDetector?.flush();
    if (pending != null) {
      for (final e in pending) {
        _controller.add(e);
      }
    }
    _controller.close();
  }
}

/// Pure translation from a notcurses key event to an [InputEvent].
///
/// Exposed as a top-level function so the mapping logic can be unit-tested
/// without a live notcurses runtime. [id] is the [nc.Key.id] codepoint;
/// [hasAlt]/[hasCtrl] are modifier flags; [isSynthesized] is the result of
/// [nc.Key.keySynthesizedP] (true for keys like arrows and function keys
/// that notcurses encodes in the synthesized-key range).
InputEvent? translateNcKey({
  required int id,
  required bool hasAlt,
  required bool hasCtrl,
  required bool isSynthesized,
}) {
  // Notcurses with extended keyboard modes delivers Ctrl+letter as
  // (id=letter, hasCtrl=true) rather than the raw C0 byte. Fold that back
  // to the C0 byte (id & 0x1F) so the switch below handles Ctrl+letter
  // uniformly whether the terminal sent raw 0x01–0x1a or the letter with
  // a modifier flag. Skip synthesized keys (arrows/functions carry hasCtrl
  // for Ctrl+Arrow etc., which is a different semantic).
  if (hasCtrl && !isSynthesized) {
    final lower = _lowerAlpha(id);
    if (lower >= 0x61 && lower <= 0x7a) {
      id = lower & 0x1F;
      hasCtrl = false;
    }
  }
  // Printable characters (ASCII or UTF-8).
  if (id >= 0x20 && id < 0x7F) {
    if (hasAlt) return AltKey(_lowerAlpha(id));
    return CharInput(String.fromCharCode(id));
  }
  // UTF-8 printable (> 0x7F and not a notcurses synthesized key).
  if (id > 0x7F && !isSynthesized) {
    if (hasAlt) return AltKey(id);
    return CharInput(String.fromCharCode(id));
  }

  // Control keys.
  if (id == 0x0d || id == nc.NcKey.enter) return ControlKey(ControlCode.enter);
  if (id == 0x09) return ControlKey(ControlCode.tab);
  if (id == 0x08 || id == 0x7f || id == nc.NcKey.backspace) {
    return ControlKey(ControlCode.backspace);
  }

  // Ctrl+letter (0x01–0x1a). Matches input_parser.dart's mappings so the
  // line editor's home/end/kill bindings work under both backends.
  if (id >= 0x01 && id <= 0x1a) {
    switch (id) {
      case 0x01: // ctrl-a
        return EditingKey(EditingAction.home);
      case 0x03: // ctrl-c
        return ControlKey(ControlCode.ctrlC);
      case 0x04: // ctrl-d
        return ControlKey(ControlCode.ctrlD);
      case 0x05: // ctrl-e
        return EditingKey(EditingAction.end);
      case 0x0b: // ctrl-k
        return EditingKey(EditingAction.killToEnd);
      case 0x0c: // ctrl-l
        return ControlKey(ControlCode.ctrlL);
      case 0x0f: // ctrl-o — panel-maximize toggle
        return ControlKey(ControlCode.ctrlO);
      case 0x15: // ctrl-u
        return EditingKey(EditingAction.killToStart);
      case 0x17: // ctrl-w
        return ControlKey(ControlCode.ctrlW);
      case 0x07: // ctrl-g — alternative to ctrl-w (terminals swallow ctrl-w)
        return ControlKey(ControlCode.ctrlG);
      default:
        // Other ctrl combos aren't bound to anything in the line editor.
        return null;
    }
  }

  // Arrow keys. Ctrl modifier propagates so FocusManager can pick up
  // Ctrl+Arrow for spatial navigation.
  if (id == nc.NcKey.up)
    return ArrowKey(ArrowDirection.up, hasCtrl: hasCtrl, hasAlt: hasAlt);
  if (id == nc.NcKey.down)
    return ArrowKey(ArrowDirection.down, hasCtrl: hasCtrl, hasAlt: hasAlt);
  if (id == nc.NcKey.left)
    return ArrowKey(ArrowDirection.left, hasCtrl: hasCtrl, hasAlt: hasAlt);
  if (id == nc.NcKey.right)
    return ArrowKey(ArrowDirection.right, hasCtrl: hasCtrl, hasAlt: hasAlt);
  if (id == nc.NcKey.pgup) return ArrowKey(ArrowDirection.pageUp);
  if (id == nc.NcKey.pgdown) return ArrowKey(ArrowDirection.pageDown);

  // Mouse scroll wheel (delivered when mice are enabled). Routed to the
  // focused panel's scrollback, never to the editor — distinct from the
  // up/down arrows that cycle command history.
  if (id == nc.NcKey.scrollUp) return ScrollEvent(up: true);
  if (id == nc.NcKey.scrollDown) return ScrollEvent(up: false);

  // Editing keys.
  if (id == nc.NcKey.home) return EditingKey(EditingAction.home);
  if (id == nc.NcKey.end) return EditingKey(EditingAction.end);
  if (id == nc.NcKey.del) return EditingKey(EditingAction.delete);

  // Function keys.
  final funcKey = _translateFunctionKey(id);
  if (funcKey != null) return FunctionKey(funcKey);

  // Alt + letter (for keys not in the printable range).
  if (hasAlt && id >= 0x61 && id <= 0x7a) {
    return AltKey(id);
  }
  if (hasAlt && id >= 0x41 && id <= 0x5a) {
    return AltKey(id + 0x20);
  }

  // ESC key.
  if (id == 0x1b) return EscapeKey();

  // Resize event — not an InputEvent we handle (SIGWINCH is handled elsewhere).
  if (id == nc.NcKey.resize) return null;

  return null;
}

/// Lowercase ASCII uppercase A–Z, leave everything else alone. Used so
/// `Alt+Shift+F` produces the same `AltKey(0x66)` the ANSI parser does, so
/// menu shortcuts match without consulting case.
int _lowerAlpha(int id) => (id >= 0x41 && id <= 0x5a) ? id + 0x20 : id;

/// Map notcurses function key codes to [FunctionKeyCode].
FunctionKeyCode? _translateFunctionKey(int id) {
  if (id == nc.NcKey.f01) return FunctionKeyCode.f1;
  if (id == nc.NcKey.f02) return FunctionKeyCode.f2;
  if (id == nc.NcKey.f03) return FunctionKeyCode.f3;
  if (id == nc.NcKey.f04) return FunctionKeyCode.f4;
  if (id == nc.NcKey.f05) return FunctionKeyCode.f5;
  if (id == nc.NcKey.f06) return FunctionKeyCode.f6;
  if (id == nc.NcKey.f07) return FunctionKeyCode.f7;
  if (id == nc.NcKey.f08) return FunctionKeyCode.f8;
  if (id == nc.NcKey.f09) return FunctionKeyCode.f9;
  if (id == nc.NcKey.f10) return FunctionKeyCode.f10;
  if (id == nc.NcKey.f11) return FunctionKeyCode.f11;
  if (id == nc.NcKey.f12) return FunctionKeyCode.f12;
  return null;
}

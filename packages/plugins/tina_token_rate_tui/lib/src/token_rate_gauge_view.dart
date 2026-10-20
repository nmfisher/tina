import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:tina_chat/observation.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'gauge.dart';

/// A status-bar contribution that shows the live output-token rate while a
/// model turn is generating.
///
/// The engine has no real tokenizer; like the transcript's token estimate,
/// tokens are derived from streamed text (utf8 bytes / 4). The gauge listens
/// to the session's chat events for `SawText` deltas, accumulates the
/// estimated tokens, and reports the sliding-window rate. It renders nothing
/// when the session is idle or the rate is negligible.
final class TokenRateGaugeView implements ConsoleContribution {
  TokenRateGaugeView(this.chat, {DateTime Function()? now})
      : _now = now ?? DateTime.now,
        _window = TokenRateWindow();

  final ChatObservation chat;
  final DateTime Function() _now;
  final TokenRateWindow _window;

  ConsoleContext? _console;
  void Function()? _release;
  Timer? _ticker;
  bool _busy = false;
  double _streamTokens = 0;
  double _lastRate = 0;

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    final events = chat.events;
    _busy = events.running;

    final unlisten = context.own(events.listen((event) {
      if (event is ObservedModel && event.event is SawText) {
        _streamTokens +=
            utf8.encode((event.event as SawText).text).length / 4.0;
        _window.sample(_now(), _streamTokens);
      }
    }));
    final unlistenState = context.own(events.listenChanges(() {
      _busy = events.running;
      if (!_busy) _reset();
      _console?.refreshStatus();
    }));
    final unbindStatus = context.bindStatus(_statusLines, priority: 50);

    _ticker = Timer.periodic(const Duration(milliseconds: 160), (_) {
      if (!_busy) return;
      poll();
    });

    _release = context.own(() {
      _ticker?.cancel();
      _ticker = null;
      unlisten();
      unlistenState();
      unbindStatus();
    });
    context.refreshStatus();
  }

  /// Recompute the rate from the current window and repaint the status if it
  /// moved. Called periodically by [_ticker] while busy; exposed for tests.
  @visibleForTesting
  void poll() {
    _window.sample(_now(), _streamTokens);
    final rate = _window.rate(_now());
    if ((rate - _lastRate).abs() >= 0.5) {
      _lastRate = rate;
      _console?.refreshStatus();
    }
  }

  List<RenderLine> _statusLines() {
    final console = _console;
    if (console == null || !_busy || _lastRate < 1) return const [];
    final theme = console.screen.theme.chat;
    return [
      RenderLine(runs: [
        RenderRun('◔ ${_formatRate(_lastRate)} tok/s', theme.dim),
      ]),
    ];
  }

  static String _formatRate(double rate) =>
      rate >= 10 ? rate.toStringAsFixed(0) : rate.toStringAsFixed(1);

  void _reset() {
    _streamTokens = 0;
    _lastRate = 0;
    _window.clear();
  }

  @override
  void repaintConsole() => _console?.refreshStatus();

  @override
  void detachConsole() {
    _release?.call();
    _release = null;
    _console = null;
  }
}

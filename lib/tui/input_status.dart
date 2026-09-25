import 'dart:async';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import '../frontend/renderers.dart';

class GitStatusRenderer extends Renderer<GitStatus> {
  const GitStatusRenderer();
  static const _frames = ['|', '/', '-', '\\'];
  @override
  List<RenderLine> render(GitStatus value, RenderContext context) {
    final text = switch (value.phase) {
      GitPhase.checking =>
        'checking… ${_frames[context.animationFrame % _frames.length]}',
      GitPhase.unavailable => 'classification unavailable',
      GitPhase.cancelled => 'classification cancelled',
      GitPhase.ready =>
        value.intent!.unknown
            ? 'Git intent unclear'
            : value.intent!.commands.isEmpty
            ? 'no Git intent'
            : 'git ${value.intent!.commands.join(', ')}',
    };
    return [
      RenderLine(
        animated: value.phase == GitPhase.checking,
        runs: [RenderRun('Last input: $text', context.theme.chat.dim)],
      ),
    ];
  }
}

class _NoStatus extends Renderer<Object> {
  const _NoStatus();
  @override
  List<RenderLine> render(Object value, RenderContext context) => const [];
}

/// Generic bridge: discovers status sources, selects the focused conversation,
/// and renders values using live plugin contributions. Owns no Git logic.
class InputStatus {
  final Screen screen;
  final PluginScope scope;
  final String Function() conversationId;
  final _sources = <StatusSource, StreamSubscription<void>>{};
  StreamSubscription<void>? _registry;
  bool _started = false;
  final _clock = Stopwatch();
  int _frame = 0;
  InputStatus({
    required this.screen,
    required this.scope,
    required this.conversationId,
  });
  void start() {
    if (_started) return;
    _started = true;
    _registry = scope.changes.listen((_) => _sync());
    _sync();
  }

  void _sync() {
    if (!_started) return;
    final live = scope.isAdmitting
        ? scope.contributions
              .map((c) => c.contribution)
              .whereType<StatusSource>()
              .toSet()
        : <StatusSource>{};
    for (final source in _sources.keys.toList()) {
      if (!live.contains(source)) unawaited(_sources.remove(source)!.cancel());
    }
    for (final source in live) {
      _sources.putIfAbsent(
        source,
        () => source.changes.listen(
          (_) => refresh(),
          onError: (Object _) => refresh(),
          onDone: refresh,
        ),
      );
    }
    // Layout contributions replace the strip's arrangement wholesale. Like
    // renderers, nearest scope first, selection within each scope in
    // registration order, first one wins; none installed restores the default.
    StatusLayout layout = const DefaultStatusLayout();
    for (
      PluginScope? current = scope;
      current != null;
      current = current.parent
    ) {
      if (!current.isAdmitting) continue;
      var found = false;
      for (final contribution in current.contributions) {
        final candidate = contribution.contribution;
        if (candidate is StatusLayout) {
          layout = candidate;
          found = true;
          break;
        }
      }
      if (found) break;
    }
    screen.setStatusLayout(layout);
    refresh();
  }

  void refresh() {
    if (!_started) return;
    final lines = <RenderLine>[];
    final renderers = Renderers(scope);
    for (final source in _sources.keys) {
      try {
        final value = source.read(conversationId());
        if (value != null)
          lines.addAll(
            renderers.render(
              value,
              RenderContext(
                width: screen.layout.width - 2,
                theme: screen.theme,
                animationFrame: _frame,
              ),
              fallback: const _NoStatus(),
            ),
          );
      } catch (_) {
        /* a status extension cannot break input */
      }
    }
    screen.setStatusLines(lines);
    final animate = !screen.passthrough && lines.any((line) => line.animated);
    if (animate && !_clock.isRunning) {
      _clock.start();
      screen.registerAnimation(_tick);
    } else if (!animate) {
      _stopAnimation();
    }
  }

  void _tick() {
    final frame = _clock.elapsedMilliseconds ~/ 120;
    if (frame == _frame) return;
    _frame = frame;
    refresh();
  }

  void _stopAnimation() {
    if (_clock.isRunning) screen.unregisterAnimation(_tick);
    _clock.stop();
    _clock.reset();
    _frame = 0;
  }

  Future<void> dispose() async {
    _started = false;
    _stopAnimation();
    await _registry?.cancel();
    for (final sub in _sources.values) {
      await sub.cancel();
    }
    _sources.clear();
    screen.setStatusLines(const []);
  }
}

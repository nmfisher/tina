import 'package:tina_console/tina_console.dart';
import 'package:tina_tasks/tina_tasks.dart';

String _safe(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');

/// A compact, read-only overview of the session's task queue. Renders as a
/// sidebar panel so it shares the right-hand column with the other inspector
/// panels; it is registered with a priority below the classification panel, so
/// it stacks underneath it. It shows the active task, the next queued task and
/// a small progress summary, and hides itself when the queue is empty.
final class TaskOverviewPanel {
  TaskOverviewPanel({required this.tasks, required this.context});
  final TaskObservation tasks;
  final ConsoleContext context;
  Screen get screen => context.screen;
  SidebarPanel? _slot;
  OverlayRegion? _region;
  bool _started = false;

  void start() {
    _started = true;
    _slot = context.bindSidebarPanel(refresh, priority: 30);
    refresh();
  }

  bool get regionVisible => _region?.isVisible == true;

  void refresh() {
    if (!_started || context.isReadingKey) return;
    final state = tasks.state;
    if (state.isEmpty || !context.isActive) {
      _slot?.requestSize(height: 0);
      _hide();
      return;
    }
    final content = _content(state);
    final height = (content.length + 2).clamp(4, 10);
    _slot?.requestSize(height: height, width: 44);
    final area = _slot!.bounds;
    if (area.isEmpty) {
      _hide();
      return;
    }
    final innerWidth = area.width - 4;
    String paint(String text) =>
        screen.colorize(screen.theme.chat.dim, text);
    String body(String text) {
      final fit = clipDialogText(_safe(text), innerWidth);
      return '${paint('│')} $fit${' ' * (innerWidth - visibleWidth(fit))} ${paint('│')}';
    }

    final title = clipDialogText(' tasks ', area.width - 2);
    final lines = [
      paint('┌$title${'─' * (area.width - 2 - visibleWidth(title))}┐'),
      for (final line in content) body(line),
      paint('└${'─' * (area.width - 2)}┘'),
    ];
    final region = _region ??= OverlayRegion(screen, area);
    if (region.isVisible &&
        (region.bounds.row != area.row ||
            region.bounds.col != area.col ||
            region.bounds.width != area.width ||
            region.bounds.height != area.height)) {
      region.hide();
      context.chat.repaint();
    }
    region.update(bounds: area, lines: lines);
  }

  List<String> _content(TaskState state) {
    final current = state.current;
    final next = state.next;
    final pending = state.pending.length;
    final total = state.items.length;
    return [
      if (current != null) '› ${current.id} ${current.text}' else 'no active task',
      if (next != null) '→ ${next.id} ${next.text}',
      '$pending pending · $total total',
    ];
  }

  void _hide() {
    if (regionVisible) {
      _region!.hide();
      context.chat.repaint();
    }
  }

  void dispose() {
    _started = false;
    _hide();
    _slot?.dispose();
    _slot = null;
    _region?.dispose();
    _region = null;
  }
}

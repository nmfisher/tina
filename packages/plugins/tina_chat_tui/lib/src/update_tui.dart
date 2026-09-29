import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_self_update/tina_self_update.dart';

PluginDefinition<C> updateTuiDefinition<C>() => PluginDefinition.dependingOn<C,
        UpdateStatusSource>('tina/update-tui',
    dependency: updateStatusSource,
    live: true,
    create: (_, status) => UpdateTuiPlugin(status),
    description:
        'Shows update availability and download progress in the status bar.');

/// Presentation subscribes to the updater's state, without coupling it to a
/// terminal. Other channels can consume the same source.
final class UpdateTuiPlugin extends AgentPlugin implements ConsoleContribution {
  UpdateTuiPlugin(this.source);
  final UpdateStatusSource source;
  @override
  String get id => 'tina/update-tui';
  ConsoleContext? _console;
  StreamSubscription<void>? _changes;
  Timer? _timer;
  void Function()? _unbind;
  int _frame = 0;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _unbind = context.bindStatus(_lines, priority: 10);
    _changes = source.changes.listen((_) => repaintConsole());
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (source.status.phase == UpdatePhase.checking) {
        _frame++;
        repaintConsole();
      }
    });
    unawaited(source.checkInBackground());
  }

  List<RenderLine> _lines() {
    final theme = _console!.screen.theme.chat;
    final status = source.status;
    String clean(String text) =>
        text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    final text = switch (status.phase) {
      UpdatePhase.current => '',
      UpdatePhase.checking =>
        'update check ${['|', '/', '-', '\\'][_frame % 4]}',
      UpdatePhase.available => 'update ⬆ ${status.tag} · /update',
      UpdatePhase.failed =>
        'update check failed — ${status.reason ?? 'unknown reason'}',
      UpdatePhase.deferred =>
        'update check deferred${status.until == null ? '' : ' · retry ${_time(status.until!)}'}',
    };
    if (text.isEmpty) return const [];
    return [
      RenderLine(runs: [
        RenderRun(clean(text),
            status.phase == UpdatePhase.available ? theme.yellow : theme.dim)
      ])
    ];
  }

  static String _time(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  void repaintConsole() => _console?.refreshStatus();
  @override
  void detachConsole() {
    _timer?.cancel();
    _timer = null;
    unawaited(_changes?.cancel());
    _changes = null;
    _unbind?.call();
    _unbind = null;
    _console = null;
  }

  @override
  void closeSession() => detachConsole();
}

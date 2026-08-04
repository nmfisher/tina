import 'dart:async';
import 'dart:io';

import '../agent/agent_event_bus.dart';
import '../agent/agent_sink.dart';
import '../permissions/preview.dart';
import '../permissions/prompt.dart';
import '../tools/tool.dart';
import 'host_interface.dart';

/// A [HostInterface] for non-interactive runs (`--prompt`) and future
/// headless/CI use. It owns no terminal: agent prose and tool lifecycle go to
/// stdout (errors/notices to stderr), permission requests are refused with a
/// hint (the policy's `--allow`/`--yolo` rules decide before the asker is ever
/// called), and every [AgentSink] call is also emitted on [eventBus] so a
/// logger or future `--json` observer can reconstruct the whole turn.
///
/// Output destinations are injected as write callbacks so the host is unit-
/// testable without faking [IOSink].
class HeadlessHost implements HostInterface {
  HeadlessHost({
    void Function(Object? object)? write,
    void Function(Object? object)? writeErr,
  })  : _write = write ?? stdout.write,
        // `write` (not `writeln`): agent notices/tool chunks carry their own
        // newlines, so an auto-appended one would double-space the output.
        _writeErr = writeErr ?? stderr.write;

  final void Function(Object?) _write;
  final void Function(Object?) _writeErr;
  final AgentEventBus _bus = AgentEventBus();

  @override
  AgentEventBus get eventBus => _bus;

  @override
  Future<PermissionResponse> askPermission(PermissionPrompt p) async {
    // Mirrors the pre-refactor non-interactive asker: a `ask` decision can't be
    // posed interactively, so refuse and point the user at the flags that would
    // have allowed it. (Policy allow/deny rules short-circuit before this.)
    _writeErr('${p.toolName}: ${p.key}\n  '
        'refused (use --allow "${p.toolName}:${p.alwaysPattern}" or --yolo)\n');
    return PermissionResponse.denyOnce;
  }

  @override
  void showMessage(String message,
      {HostMessageStyle style = HostMessageStyle.normal}) {
    _sinkFor(style).call(message);
  }

  @override
  void showSeparator() => _write('\n');

  @override
  void showPreview(List<PreviewEntry> preview) {
    // Headless runs never block on a permission modal (the asker auto-denies),
    // so there is no preview surface to render.
  }

  @override
  void clear() {}

  @override
  void setActivity(bool active) {}
  @override
  void setIdle(bool active) {}
  @override
  void setActive(bool active) {}

  @override
  void handleResize() {}

  @override
  Future<void> dispose() async {
    _bus.dispose();
    await stdout.flush();
  }

  // --- AgentSink: render to stdout/stderr and mirror each call on the bus ---

  @override
  void text(String s) {
    _write(s);
    _bus.emit(TextAgentEvent(s));
  }

  @override
  void newline() => _write('\n');

  @override
  void toolStart(ToolStartEvent e) {
    _write('→ ${_describe(e.toolName, e.input)}\n');
    _bus.emit(ToolAgentEvent(e));
  }

  @override
  void toolOutput(ToolOutputEvent e) {
    (e.stderr ? _writeErr : _write).call(e.chunk);
    _bus.emit(ToolAgentEvent(e));
  }

  @override
  void toolComplete(ToolCompleteEvent e) {
    _write(e.isError ? '  failed: ${_truncate(e.result, 200)}\n' : '  ok\n');
    _bus.emit(ToolAgentEvent(e));
  }

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {
    _sinkFor(_noticeStyle(kind)).call(message);
    _bus.emit(NoticeAgentEvent(message, kind));
  }

  @override
  void activityStart() {}

  @override
  void activityStop() {}

  // --- helpers ---

  void Function(Object?) _sinkFor(HostMessageStyle style) =>
      style == HostMessageStyle.error || style == HostMessageStyle.warning
          ? _writeErr
          : _write;

  HostMessageStyle _noticeStyle(NoticeKind kind) => switch (kind) {
        NoticeKind.error => HostMessageStyle.error,
        NoticeKind.warning => HostMessageStyle.warning,
        NoticeKind.info => HostMessageStyle.normal,
      };

  String _describe(String name, Map<String, dynamic> input) {
    switch (name) {
      case 'bash':
        final cmd = input['command'] as String?;
        return cmd != null ? 'bash: ${_truncate(cmd, 80)}' : name;
      case 'read':
      case 'write':
      case 'edit':
        final path = input['filePath'] as String?;
        return path != null ? '$name: $path' : name;
      default:
        return name;
    }
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}

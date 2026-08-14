import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// The interactive permission asker for workflow node agents — the
/// `launch_workflow` counterpart of the main conversation's
/// `TuiConversationHost.askPermission`. A workflow runs in a background run
/// panel whose host is `active: false`, so the host's own asker would
/// auto-deny; this asker instead renders the prompt into that run's sink
/// (so it lands in the panel the user is watching) and captures the
/// `y/n/a/d` key through the shared [editor].
///
/// "Always" answers are remembered by the agent on the run's shared
/// `PermissionPolicy` (see `PipelineRunner`), so they hold for every node in
/// the run and expire with it.
class WorkflowPermissionAsker {
  /// The run's sink — the ask renders into the run panel hosting this node.
  final AgentSink sink;

  final Screen? screen;
  final LineEditor? editor;

  WorkflowPermissionAsker({
    required this.sink,
    this.screen,
    this.editor,
  });

  bool get _interactive => screen != null && editor != null;

  Future<PermissionResponse> ask(PermissionPrompt p) async {
    // Headless wiring never builds an asker at all (the scheduler's
    // auto-deny asker fields those); this guard is for a TUI that lost its
    // editor mid-run. Same posture: deny rather than block a background run.
    if (!_interactive) {
      sink.notice('${p.toolName} denied — no interactive asker',
          kind: NoticeKind.warning);
      return PermissionResponse.denyOnce;
    }

    _write('  ${p.toolName}: ${p.key}\n', HostMessageStyle.warning);
    final preview = await previewToolCall(p.toolName, p.input);
    for (final entry in preview) {
      switch (entry) {
        case PreviewHeader(:final text):
          _write('  $text\n', HostMessageStyle.dim);
        case PreviewAdded(:final text):
          _write('  + $text\n', HostMessageStyle.success);
        case PreviewRemoved(:final text):
          _write('  - $text\n', HostMessageStyle.error);
        case PreviewContext(:final text):
          _write('    $text\n', HostMessageStyle.dim);
        case PreviewSeparator():
          _write('  ⋯\n', HostMessageStyle.dim);
      }
    }
    _write(
        '  approve? [y/n/a/d]  (a/d remember "${p.alwaysPattern}") › ',
        HostMessageStyle.normal);
    final event = await editor!.readKey();
    final ch = event is CharInput ? event.text.toLowerCase() : '';
    _write('$ch\n', HostMessageStyle.normal);
    switch (ch) {
      case 'y':
        return PermissionResponse.allowOnce;
      case 'a':
        return PermissionResponse.allowAlways;
      case 'd':
        return PermissionResponse.denyAlways;
      default:
        return PermissionResponse.denyOnce;
    }
  }

  /// Render through the sink, using the host's message styles when it has
  /// them (the TUI run-panel host) and notices otherwise.
  void _write(String text, HostMessageStyle style) {
    final s = sink;
    if (s is HostInterface) {
      s.showMessage(text, style: style);
    } else {
      s.notice(text.trimRight());
    }
  }
}

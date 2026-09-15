import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../host/tui_conversation_host.dart';
import '../tui/attention_queue.dart';

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
/// the run and expire with it. When [attentionQueue] is given, asks queue
/// behind any other open modal (gates, other runs' prompts) instead of
/// racing on the keyboard.
class WorkflowPermissionAsker {
  /// The run's sink — the ask renders into the run panel hosting this node.
  final AgentSink sink;

  final Screen? screen;
  final LineEditor? editor;
  final AttentionQueue? attentionQueue;

  /// The policy whose [PermissionPolicy.mode] the ask header reports (#51b).
  /// Null when the caller has no policy to surface — the chip is omitted.
  /// Read at ask time, so `/permissions` / Shift+Tab changes apply to the
  /// next ask without rebuilding the asker.
  final PermissionPolicy? policy;

  WorkflowPermissionAsker({
    required this.sink,
    this.screen,
    this.editor,
    this.attentionQueue,
    this.policy,
  });

  bool get _interactive => screen != null && editor != null;

  Future<PermissionResponse> ask(PermissionPrompt p) {
    final queue = attentionQueue;
    if (queue == null) return _ask(p);
    return queue.run(
      () => _ask(p),
      onQueued: () {
        sink.notice(
          'waiting for your input — another dialog is open…',
          kind: NoticeKind.info,
        );
      },
    );
  }

  Future<PermissionResponse> _ask(PermissionPrompt p) async {
    // Headless wiring never builds an asker at all (the scheduler's
    // auto-deny asker fields those); this guard is for a TUI that lost its
    // editor mid-run. Same posture: deny rather than block a background run.
    if (!_interactive) {
      sink.notice(
        '${p.toolName} denied — no interactive asker',
        kind: NoticeKind.warning,
      );
      return const PermissionResponse(
        PermissionDecision.deny,
        // #27: the model only sees the denial through the tool result —
        // tell it the refusal is structural so it stops rephrasing.
        note:
            'Non-interactive run: permission asks are auto-refused — '
            'rephrasing will not change this. Proceed without this tool or '
            'answer from what you have.',
      );
    }

    // Streamed prose ends mid-row (no trailing newline); the prompt must
    // start a fresh row, not glue onto it (#30).
    if (sink is TuiConversationHost) {
      final host = sink as TuiConversationHost;
      host.chat.ensureNewline();
    }
    _write('  ${p.toolName}: ${p.key}\n', HostMessageStyle.warning);
    // The mode chip rides under the header (#51b) — dim, so it reads as
    // metadata, not as part of the call being approved.
    final policy = this.policy;
    if (policy != null) {
      _write('  ${permissionModeChip(policy.mode)}\n', HostMessageStyle.dim);
    }
    if (p.execution != null) {
      _write(p.execution!.approvalDescription, HostMessageStyle.dim);
    }
    if (p.sandboxAccess != null || p.outsideSandbox) {
      _write(p.accessDescription, HostMessageStyle.warning);
    }
    final preview = await previewToolCall(p.toolName, p.input, preparedEdit: p.preparedEdit);
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
    // The prompt writes to chat; streamed prose ends mid-row (no trailing
    // newline), so the first prompt line must start a fresh row (#30).
    if (sink is TuiConversationHost) {
      final host = sink as TuiConversationHost;
      host.chat.ensureNewline();
    }
    // Approval is a selectable list (up/down arrows) with Enter to confirm.
    final isSandboxAccess = p.sandboxAccess != null;
    final options = [
      (text: p.outsideSandbox ? 'run outside sandbox once' : 'allow once', key: 'y'),
      (
        text: p.outsideSandbox ? 'outside for session'
            : isSandboxAccess ? 'session directories' : 'allow always',
        key: 'a',
      ),
      (text: 'deny', key: 'd'),
    ];
    var selectedIndex = 0;
    final optionStr = options.map((o) => '[${o.key}] ${o.text}').join(' ');
    _write('  approve? $optionStr ‹ ', HostMessageStyle.normal);
    // If the user is mid-prompt (a readLine in flight WITH unsent content),
    // the approval must not steal their typing — the prompt's Enter would
    // answer this readKey as a deny (it is not y/a/d) and the prompt would
    // never be submitted. Wait for the readLine to submit before arming;
    // the approval's own row stays visible meanwhile.
    //
    // The TUI's input loop ALWAYS sits in readLine (the next prompt is armed
    // the moment the current one submits), so an empty pending readLine must
    // NOT trigger the wait — that deadlocks every approval behind the user's
    // next prompt (live vanish in the sweep runs: 22 queued 'y's, the
    // approval never armed).
    final pending = editor!.pendingLine;
    if (pending != null && editor!.editState.buffer.isNotEmpty) {
      if (p.cancelSignal == null) {
        await pending.catchError((_) => '');
      } else {
        final stopped = await Future.any([
          pending.then((_) => false, onError: (_) => false),
          p.cancelSignal!.then((_) => true),
        ]);
        if (stopped) return PermissionResponse.denyOnce;
      }
    }
    // globalKeys: the focus ring's shortcuts cycle panels, they must not
    // answer the approval (tin-c5nw).
    //
    // Approval is a selectable list: up/down arrows to choose, Enter to confirm.
    // Old y/n/a/d keys still work as shortcuts. Esc still denies — the
    // "get me out" key keeps its meaning.
    // #51c: exactly ONE dimmed ack per ask — the first non-answer key proves
    // the prompt is alive (its keys are being swallowed), later ones stay
    // silent so a wheel spam or a stuck key can't flood the transcript.
    var ackedIgnoredKey = false;
    while (true) {
      final event = await editor!.readKey(globalKeys: true, cancelSignal: p.cancelSignal);
      if (event is CharInput) {
        switch (event.text.toLowerCase()) {
          case 'y':
            _write('y\n', HostMessageStyle.normal);
            return PermissionResponse.allowOnce;
          case 'a':
            _write('a\n', HostMessageStyle.normal);
            return PermissionResponse.allowAlways;
          case 'd':
            if (p.outsideSandbox) return PermissionResponse.denyOnce;
            if (isSandboxAccess) break;
            _write('d\n', HostMessageStyle.normal);
            return PermissionResponse.denyAlways;
          case 'n':
            _write('n\n', HostMessageStyle.normal);
            return PermissionResponse.denyOnce;
        }
      } else if (event is ArrowKey) {
        // Up/down arrows cycle through the approval options.
        if (event.direction == ArrowDirection.up) {
          if (selectedIndex > 0) selectedIndex--;
        } else if (event.direction == ArrowDirection.down) {
          if (selectedIndex < options.length - 1) selectedIndex++;
        }
        // Redraw the approval row with updated selection.
        _write('\x1b[1A\x1b[2K', HostMessageStyle.normal); // move up and clear
        final optionStr = options.map((o) => '[${o.key}] ${o.text}').join(' ');
        _write('  approve? $optionStr ‹ ', HostMessageStyle.normal);
      } else if (event is EscapeKey) {
        _write('esc\n', HostMessageStyle.normal);
        return PermissionResponse.denyOnce;
      } else if (event is ControlKey && event.code == ControlCode.ctrlC) {
        _write('cancelled\n', HostMessageStyle.normal);
        return PermissionResponse.denyOnce;
      } else if (event is ControlKey && event.code == ControlCode.enter) {
        final selected = options[selectedIndex];
        _write(selected.text, HostMessageStyle.normal);
        switch (selected.key) {
          case 'y':
            _write('\n', HostMessageStyle.normal);
            return PermissionResponse.allowOnce;
          case 'a':
            _write('\n', HostMessageStyle.normal);
            return PermissionResponse.allowAlways;
          case 'd':
            if (p.outsideSandbox) return PermissionResponse.denyOnce;
            if (isSandboxAccess) continue;
            _write('\n', HostMessageStyle.normal);
            return PermissionResponse.denyAlways;
          default:
            continue;
        }
      }
      // Not an answer key: the read stays armed. One-shot ack on the first
      // one that surfaces here; keys the focus ring consumes (panel cycling)
      // never reach this loop and get no ack — that is the point of #51c,
      // feedback for keys the prompt itself swallowed.
      if (!ackedIgnoredKey) {
        ackedIgnoredKey = true;
        _write(ignoredKeyAck, HostMessageStyle.dim);
      }
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

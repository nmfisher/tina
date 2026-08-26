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
    // The prompt writes to chat; streamed prose ends mid-row (no trailing
    // newline), so the first prompt line must start a fresh row (#30).
    if (sink is TuiConversationHost) {
      final host = sink as TuiConversationHost;
      host.chat.ensureNewline();
    }
    _write(approvalPromptRow(p.alwaysPattern), HostMessageStyle.normal);
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
      await pending.catchError((_) => '');
    }
    // globalKeys: the focus ring's shortcuts cycle panels, they must not
    // answer the approval (tin-c5nw).
    //
    // Only the answer keys decide. Anything else — arrows, Enter, stray
    // characters, pastes, wheel notches — is NOT an answer and must not
    // decide it: the read simply stays armed and the next key is heard (an
    // up-arrow used to fall into the default-deny and silently reject the
    // action). Esc still denies — the "get me out" key keeps its meaning.
    // #51c: exactly ONE dimmed ack per ask — the first non-answer key proves
    // the prompt is alive (its keys are being swallowed), later ones stay
    // silent so a wheel spam or a stuck key can't flood the transcript.
    var ackedIgnoredKey = false;
    while (true) {
      final event = await editor!.readKey(globalKeys: true);
      if (event is CharInput) {
        switch (event.text.toLowerCase()) {
          case 'y':
            _write('y\n', HostMessageStyle.normal);
            return PermissionResponse.allowOnce;
          case 'a':
            _write('a\n', HostMessageStyle.normal);
            return PermissionResponse.allowAlways;
          case 'd':
            _write('d\n', HostMessageStyle.normal);
            return PermissionResponse.denyAlways;
          case 'n':
            _write('n\n', HostMessageStyle.normal);
            return PermissionResponse.denyOnce;
        }
      } else if (event is EscapeKey) {
        _write('esc\n', HostMessageStyle.normal);
        return PermissionResponse.denyOnce;
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

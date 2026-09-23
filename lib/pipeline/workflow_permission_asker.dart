import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../frontend/renderers.dart';
import '../host/tui_conversation_host.dart';
import '../tui/attention_queue.dart';
import '../tui/permission_approval.dart';

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

  /// The model that drafts general-but-safe regex patterns for the `[r]`
  /// rewrite choice; null keeps the literal escape as the only seed.
  final RegexSuggester? regexSuggester;

  WorkflowPermissionAsker({
    required this.sink,
    this.screen,
    this.editor,
    this.attentionQueue,
    this.policy,
    this.regexSuggester,
  });

  bool get _interactive => screen != null && editor != null;

  Future<PermissionResponse> ask(PermissionPrompt p) {
    final queue = attentionQueue;
    if (queue == null) return _ask(p);
    return queue.run(
      () => _ask(p),
      onCancel: () => PermissionResponse.denyOnce,
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
    final response = await runPermissionApproval(
      screen: screen!,
      editor: editor!,
      prompt: p,
      policy: policy,
      regexSuggester: regexSuggester,
      renderers: sink is TuiConversationHost
          ? (sink as TuiConversationHost).renderers
          : const Renderers(),
      sandboxWarning: sink is TuiConversationHost
          ? sandboxOffChip((sink as TuiConversationHost).sandboxOffReason)
          : null,
      write: (text) => _write(text, HostMessageStyle.normal),
      // The run panel's transcript is the host's, so queueing there prints the
      // record after the node's tool row — the call stays in the transcript
      // exactly once. Any other sink has no transcript of ours to interleave
      // with, so its record lands immediately.
      onSettled: sink is TuiConversationHost
          ? (sink as TuiConversationHost).transcript.queueApproval
          : (record) => _write(record, HostMessageStyle.normal),
    );
    // A refusal or a cancel never reaches the tool row its record would wait
    // behind: print it now, ahead of the denial the executor is about to
    // notice. (An allowed call keeps it queued for its row.)
    if (sink is TuiConversationHost &&
        response.decision != PermissionDecision.allow) {
      (sink as TuiConversationHost).transcript.flushApproval();
    }
    return response;
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

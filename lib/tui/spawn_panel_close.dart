import 'package:tina_app/tina_app.dart';

import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina_console/tina_console.dart' show PanelFrame;

/// Ctrl+X policy for spawned conversation panels: decide whether the focused
/// frame may close, run the close, and restore focus — nothing else.
///
/// The gesture is wired in one place ([TuiCoordinator.create]'s
/// `editor.onClosePanel`): a focused spawned-panel frame, plus [onRunPanel]
/// for the read-only workflow run panels (their `x` key in chord form). The
/// primary frame is never closable (a session must keep its conversation).
///
/// The steps below are named because they are load-bearing — dropping one
/// leaves a zombie panel, an active pointer at a removed conversation, or a
/// focus ring entry pointing at a disposed frame:
///
/// 1. [SessionManager.closeConversation] — removes the Conversation,
///    `_deferRelease`s its resources (host/provider/turn futures), and
///    re-anchors the session's in-memory active conversation when needed. It
///    does NOT remove the frame or repoint focus (UI-agnostic).
/// 2. [ConversationPanelCoordinator.unbindSpawned] — drops the frame↔host
///    binding before teardown so pending callbacks can't repaint a frame
///    that's going away.
/// 3. [PanelManager.removeFrame] — unregisters the frame from the focus ring
///    and, when it held focus, homes focus and the shared input back onto the
///    primary frame.
/// 4. Re-split policy: [PanelManager.applyScreenLayout] +
///    [ConversationPanelCoordinator.relayContent] shrink back to the full-width
///    chat when the last spawned panel closes; [refreshLayout] is the
///    canonical sequence (the same closure first-spawn uses to split).
/// 5. Tree cleanup — [SpawnTree.parentOf] / [baseLabel] entries removed so the
///    sidebar, DFS order, and depth indents stop listing it.
class SpawnPanelCloseController {
  SpawnPanelCloseController({
    required this.sessionManager,
    required this.panelManager,
    required this.contentCoordinator,
    required this.refreshLayout,
    this.onRunPanel,
  });

  final SessionManager sessionManager;
  final PanelManager panelManager;
  final ConversationPanelCoordinator contentCoordinator;

  /// The canonical resize sequence (first-spawn's closure): re-applies the
  /// split policy for the current panel set, retiles, relays content, and
  /// repoints the input.
  final void Function() refreshLayout;

  /// Close path for non-conversation frames (workflow run panels): returns
  /// true when [frame] was a run panel and was closed. Null when no run-panel
  /// host exists.
  final bool Function(PanelFrame frame)? onRunPanel;

  /// Attempt to close the currently focused panel. Returns true when a panel
  /// was closed (the editor consumes Ctrl+X); false when nothing qualifies
  /// (home, or a panel with no session) — the key is then dropped, never
  /// typed.
  bool closeFocused() {
    final frame = panelManager.focusManager.focused;
    if (frame is! PanelFrame) return false;
    if (frame == panelManager.primaryFrame) return false;
    if (onRunPanel?.call(frame) ?? false) return true;
    return _closeSpawned(frame);
  }

  /// Close one spawned conversation panel end to end. Returns false when the
  /// conversation is unknown (already closed elsewhere).
  bool _closeSpawned(PanelFrame frame) {
    final id = frame.conversationId;
    final session = sessionManager.active;
    if (session.conversationById(id) == null) return false;

    // 1. Drop the conversation from the session (resources deferred-release).
    //    Before the frame teardown: once the conversation is gone the
    //    coordinator's active-frame resolution would fall back to the primary
    //    anyway, and a streaming agent writing into a removed conversation
    //    must not keep the panel alive.
    sessionManager.closeConversation(session.id, id);

    // 2. Unbind the frame↔host pair (hooks nulled, content detached) BEFORE
    //    the chrome teardown, so a queued busy tick can't repaint a disposed
    //    frame (mirrors the coordinator's dispose() ordering).
    contentCoordinator.unbindSpawned(frame);

    // 3+4. Remove the frame (focus ring + homing) and re-apply the split
    //    policy — both go through the canonical layout sequence. removeFrame
    //    has already homed focus onto the primary when the closed frame held
    //    it; refreshLayout's relocateInput then re-points the shared input at
    //    the primary's chat.
    panelManager.removeFrame(frame);
    refreshLayout();

    // 5. Tree edges last: the relayout inside refreshLayout already ran on
    //    the smaller frame list, but the sidebar/DFS/depth computations read
    //    these maps — stale entries would keep a removed conversation in the
    //    sidebar (and re-dangle its children under the root).
    panelManager.tree.parentOf.remove(id);
    panelManager.tree.baseLabel.remove(id);
    return true;
  }
}

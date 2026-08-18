import 'dart:async';

import 'package:tina_console/tina_console.dart';

import '../host/tui_conversation_host.dart';
import '../session_manager.dart';
import 'panel_manager.dart';

/// Whether spawned panels use the frame-owns-canvas model: the [PanelFrame]
/// owns the chat's [BackendSurface] and the region borrows it, so geometry
/// flows one way and can't go stale. false keeps the legacy region-owns-surface
/// model.
const _frameOwnedCanvas = true;

/// The single place that knows about *both* panel chrome and the conversations
/// they frame.
///
/// `PanelManager` owns geometry, the focus ring, and shared-input relocation —
/// it is content-agnostic. `TuiConversationHost` owns a conversation's chat
/// region and routes its output. Neither knows about the other; this
/// coordinator is the binding layer between them:
///
/// * conversation → frame + [PanelContent] mapping ([_bindings]);
/// * content positioning every time geometry changes ([relayContent]);
/// * focus → active-conversation wiring ([onFrameFocused]): focusing a side
///   panel routes input to it without repointing the manifest anchor;
/// * the host's busy cue, inverted from a typed [TuiConversationHost.panel] field
///   into an [TuiConversationHost.onBusyChanged] callback so the host never
///   reaches into a [PanelFrame].
///
/// Content relay deliberately never **detaches**: it only ever `fit`s each
/// content surface into its (new) interior and `attach`es it if still
/// detached. This matches the pre-extraction relay exactly. Detaching the
/// primary when a side panel is focused would regress the
/// primary-stays-visible invariant the host's `stayAttachedWhenInactive`
/// preserves (pinned by the focus characterization tests), so detach stays the
/// host's job and this coordinator only ever makes content visible.
class ConversationPanelCoordinator {
  ConversationPanelCoordinator({
    required this.panelManager,
    required this.sessionManager,
    required this.editor,
    required this.primaryHost,
  });

  final PanelManager panelManager;
  final SessionManager sessionManager;
  final LineEditor editor;
  final TuiConversationHost primaryHost;

  final Map<String, _ContentBinding> _bindings = {};

  /// Non-conversation panels (e.g. workflow run views): frame → content, no
  /// host binding. Positioned by [relayContent] like any other panel; focusing
  /// one keeps the shared input on the primary chat (there is no conversation
  /// to route input to).
  final Map<PanelFrame, PanelContent> _extra = {};

  /// The primary conversation id, set in [bindPrimary]. Stable for the session's
  /// life (the primary Conversation is reused across /clear), so it identifies
  /// the primary reliably in [onFrameFocused] — mirroring the pre-extraction
  /// `conv.id == initialConversationId` check.
  String? _primaryConversationId;

  /// Wire a frame↔host pair for scrollback: PgUp/PgDn on the frame scroll the
  /// host's chat by one page, and the chat's scrollback-change notification
  /// drives the frame's "↓ N new" badge. Each closure captures its own host
  /// (mirrors [onFocus]/[onBusyChanged]).
  void _wireScrollback(PanelFrame frame, TuiConversationHost host) {
    frame.onScroll = (deltaPages) {
      final page = host.chat.usableHeight;
      host.chat.scrollBy(deltaPages * (page > 0 ? page : 1));
    };
    // The mouse wheel scrolls the same scrollback, 3 rows per notch.
    frame.onWheel = (deltaRows) => host.chat.scrollBy(deltaRows);
    host.chat.onScrollbackChanged = () {
      frame.setScrollBadge(host.chat.newWhileScrolled);
    };
  }

  /// Bind the primary conversation to the primary frame. The primary host's
  /// chat is the shared `screen.chat`; wrap it in a [ChatRegionPanelContent] so
  /// the frame can (re)position it, and wire the host's busy cue to the frame
  /// chrome via the inverted [onBusyChanged] callback.
  void bindPrimary({required String conversationId}) {
    final frame = panelManager.primaryFrame;
    _bindings[conversationId] = _ContentBinding(
      conversationId: conversationId,
      frame: frame,
      content: ChatRegionPanelContent(primaryHost.chat),
      host: primaryHost,
    );
    frame.setReservesInput(true);
    frame.onFocus = () => onFrameFocused(frame);
    // Keep the panel back-reference for paths that need chrome access
    // (host.clear() repaints it; openModelPicker's /model relabels it). The
    // busy *cue*, though, is inverted onto onBusyChanged below.
    primaryHost.panel = frame;
    primaryHost.onBusyChanged = (busy) => frame.setBusy(busy);
    _wireScrollback(frame, primaryHost);
    // Not _positionContent here: the primary frame has no bounds until the
    // first-paint layout. relayContent() (first-paint + every resize) fits it.
    _primaryConversationId = conversationId;
  }

  /// Create and bind a frame for a spawned/branch/sub-agent conversation.
  /// Registers it in the tiling list + focus ring, wires its focus to
  /// [onFrameFocused] (the ONLY place a frame's onFocus is set), and inverts the
  /// host's busy cue onto the frame chrome. Returns the created frame so
  /// callers can record tree edges and focus it.
  ///
  /// Takes the [host] (not the [Conversation]): the panel is built and bound
  /// before the sub-agent/branch [Conversation] is minted, so the host is the
  /// only identity available up-front. The binding is keyed by
  /// [TuiConversationHost.conversationId], which matches the conversation id set
  /// later.
  PanelFrame bindSpawned({
    required TuiConversationHost host,
    required String label,
  }) {
    final frame = PanelFrame(
      screen: panelManager.screen,
      label: label,
      conversationId: host.conversationId,
      ownsCanvas: _frameOwnedCanvas,
    );
    final binding = _ContentBinding(
      conversationId: host.conversationId,
      frame: frame,
      content: ChatRegionPanelContent(host.chat),
      host: host,
    );
    _bindings[host.conversationId] = binding;

    frame.setReservesInput(true);
    // The coordinator owns onFocus (see class doc). Sub-agent panels re-point
    // this later via a focus rebind once their Conversation is minted.
    frame.onFocus = () => onFrameFocused(frame);
    panelManager.addFrame(frame);

    // Keep the panel back-reference for chrome paths (clear()/relabel); invert
    // the busy cue onto onBusyChanged so the host never reaches into a frame
    // just to drive its comet.
    host.panel = frame;
    host.onBusyChanged = (busy) => frame.setBusy(busy);
    _wireScrollback(frame, host);

    // Not _positionContent here: the frame has no bounds until layout. The
    // post-bind relayContent() (first-paint, resize, spawn) fits it.
    return frame;
  }

  /// Focusing [frame] makes its conversation the active input target. Mirrors
  /// the pre-extraction `onPanelFocused`: raise the focused chat surface above
  /// its siblings, switch the in-memory active conversation (without moving the
  /// manifest anchor unless this is the primary), then repoint the shared input
  /// onto the focused frame.
  void onFrameFocused(PanelFrame frame) {
    final binding = _bindings.values.firstWhere((b) => b.frame == frame);
    final s = binding.content.surface;
    if (s != null) panelManager.screen.raiseChatSurface(s);

    final session = sessionManager.active;
    if (session.activeConversationId == binding.conversationId) {
      panelManager.relocateInput(frame);
      return;
    }
    // A host-only panel — bound by id but never registered as a Conversation
    // in the session (the first-load environment agent's panel) — has no
    // conversation to route input to, and switching would throw. Focus then
    // behaves like an extra panel: the surface still raises, the shared input
    // stays on the primary chat.
    if (session.conversationById(binding.conversationId) == null) {
      panelManager.relocateInput(panelManager.primaryFrame);
      return;
    }
    // Focusing a side panel routes input to it (in-memory active follows
    // focus) but must NOT repoint the session manifest's activeConversationId
    // anchor at it — that anchor decides which conversation becomes the
    // full-width slot on resume, so it must always be the primary. The primary
    // id is stable for the session's life (the primary Conversation is reused
    // across /clear), so it identifies the primary reliably here — exactly the
    // pre-extraction `conv.id == initialConversationId` check.
    final isPrimary = binding.conversationId == _primaryConversationId;
    unawaited(sessionManager
        .switchConversation(binding.conversationId, persist: isPrimary)
        .then((_) {
      panelManager.relocateInput(frame);
    }));
  }

  /// Relay content into every frame's freshly-resigned interior and attach
  /// detached ones. The post-layout step the eventual resize sequence takes
  /// over: position every [PanelContent] (conversation bindings and extra
  /// panels alike) to match its frame's current interior. Never detaches — see
  /// the class doc.
  void relayContent() {
    for (final b in _bindings.values) {
      _positionContent(b.frame, b.content);
    }
    for (final entry in _extra.entries) {
      _positionContent(entry.key, entry.value);
    }
  }

  /// Coordinator policy: position one content surface into its frame's
  /// interior and make it visible. Only ever attaches (if detached); the host's
  /// `setActive`/`stayAttachedWhenInactive` governs the primary's detach, so
  /// this stays a pure "make it visible" step.
  void _positionContent(PanelFrame frame, PanelContent content) {
    // Frame-owns-canvas: when the frame owns a surface, hand it to the content
    // so geometry flows from the frame (single source). No-op when the frame
    // has no surface (legacy mode, or a backend that can't provide one).
    final surface = frame.surface;
    if (surface != null) content.bindSurface(surface);
    content.fit(frame.interior, reserveInputRow: frame.reservesInput);
    if (content.isDetached) content.attach();
  }

  /// Register a non-conversation panel (a workflow run view). No host binding:
  /// [relayContent] fits the content; focusing the frame keeps the shared input
  /// on the primary chat (there is no conversation to route input to).
  void bindExtra({required PanelFrame frame, required PanelContent content}) {
    _extra[frame] = content;
    frame.setReservesInput(false);
    frame.onFocus = () => panelManager.relocateInput(panelManager.primaryFrame);
    panelManager.addFrame(frame);
  }

  /// Remove and detach an extra panel's content. The caller is responsible for
  /// removing the frame itself ([PanelManager.removeFrame]).
  void unbindExtra(PanelFrame frame) {
    _extra.remove(frame)?.detach();
  }

  /// Repoint the shared input onto the frame that owns the active
  /// conversation. Resolves the active frame the same way the pre-extraction
  /// `_activeFrame` did, then delegates the content-agnostic retarget to the
  /// manager.
  void relocateInput({bool force = false}) {
    panelManager.relocateInput(_activeFrame(), force: force);
  }

  PanelFrame _activeFrame() {
    final activeId = sessionManager.activeConversationId;
    return panelManager.primaryFrame.conversationId == activeId
        ? panelManager.primaryFrame
        : panelManager.spawnedFrames.firstWhere(
            (p) => p.conversationId == activeId,
            orElse: () => panelManager.primaryFrame,
          );
  }

  void relabel(String conversationId, String label) {
    _bindings[conversationId]?.frame.relabel(label);
  }

  /// The chat surface for [conversationId], for callers that parent overlays
  /// (image rendering) onto the focused panel's plane. null when the panel has
  /// no surface.
  BackendSurface? surfaceOf(String conversationId) =>
      _bindings[conversationId]?.content.surface;

  void dispose() {
    for (final b in _bindings.values) {
      // Drop scrollback callbacks first so a pending microtask can't repaint a
      // frame we're about to tear down.
      b.host.chat.onScrollbackChanged = null;
      b.frame.onScroll = null;
      b.frame.onWheel = null;
      b.content.detach();
    }
    _bindings.clear();
    for (final c in _extra.values) {
      c.detach();
    }
    _extra.clear();
  }
}

class _ContentBinding {
  _ContentBinding({
    required this.conversationId,
    required this.frame,
    required this.content,
    required this.host,
  });

  final String conversationId;
  final PanelFrame frame;
  final PanelContent content;
  final TuiConversationHost host;
}

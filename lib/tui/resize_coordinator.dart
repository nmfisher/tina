import 'package:tina_console/tina_console.dart';

import '../session_manager.dart';
import 'panel_manager.dart';

/// Owns the single canonical resize sequence.
///
/// Today the same sequence is scattered across the SIGWINCH handler and the
/// three create-time first-split blocks — each runs `screen.resize →
/// sessionManager.handleResize → menuBar.render → editor.handleResize`, with the
/// first two also flipping `stayAttachedWhenInactive` and no single first-paint
/// call site. `ResizeCoordinator` collapses all of these to one call site.
///
/// The order is load-bearing and pinned by the coordinator characterization
/// tests: resize the screen, reconcile every chat region's row buffer, repaint
/// the menu, retile every frame (their interiors change), relay content into
/// the resized interiors, then repoint the shared input onto the active panel.
///
/// Content relay and input relocation are passed in as callbacks: in Phase 4
/// they are the coordinator's hoisted `_relayContent`/`_relocateInput`; in
/// Phase 5 they migrate to the [ConversationPanelCoordinator]. This keeps
/// `ResizeCoordinator` content-agnostic so it can be unit-tested against
/// recording fakes.
class ResizeCoordinator {
  ResizeCoordinator({
    required this.sessionManager,
    required this.menuBar,
    required this.editor,
    required this.panelManager,
    required this.relayContent,
    required this.relocateInput,
  });

  final SessionManager sessionManager;
  final MenuBar menuBar;
  final LineEditor editor;
  final PanelManager panelManager;

  /// Relay content into every frame's freshly-resized interior. Phase 4: the
  /// coordinator's hoisted `_relayContent`; Phase 5: `contentCoordinator`.
  final void Function() relayContent;

  /// Repoint the shared input onto the active panel. Phase 4: the coordinator's
  /// hoisted `_relocateInput`; Phase 5: `contentCoordinator`.
  final void Function({bool force}) relocateInput;

  void handleResize({required bool split, required bool drawInfoFrame}) {
    panelManager.applyScreenLayout(split: split, drawInfoFrame: drawInfoFrame);
    sessionManager.handleResize();
    menuBar.render();
    editor.handleResize();
    panelManager.layout();
    relayContent();
    relocateInput(force: true);
  }
}

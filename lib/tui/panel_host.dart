import 'package:tina_engine/tina_engine.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina/tui/resize_coordinator.dart';
import 'package:tina/tui/run_panel_content.dart';
import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina_console/tina_console.dart';

/// A request to open a panel, expressed without UI types: a title, the
/// conversation id its content streams under, and a [PanelPlacement] hint.
/// This is the record the panel-provider seam passes across (the design of
/// record's `PanelSpec`): renderable by any backend, so a future non-terminal
/// host can accept it unchanged.
typedef PanelSpec = ({
  String label,
  String conversationId,
  PanelPlacement placement,
});

/// Where a panel wants to appear. The host interprets (or ignores) the hint;
/// specs never carry geometry.
enum PanelPlacement {
  /// Tile into the right column, splitting the layout open on the first
  /// panel (what every spawned-style panel does today).
  sideColumn,
}

/// The live view of one panel the host opened, with the actions its panel
/// keys mean. Returned synchronously by [PanelHost.openPanel] — and the sink
/// host it carries is installed via the `installSink` hook *before* the
/// launch stream can start, which is the whole reason the open path may
/// never go async.
class OpenedPanel {
  OpenedPanel({
    required this.frame,
    required this.content,
    required this.host,
    required this.onStop,
    required this.onClose,
  });

  /// The panel chrome (title, rails, busy cue, key dispatch).
  final PanelFrame frame;

  /// The read-only transcript bound into the frame.
  final RunPanelContent content;

  /// The spawned-style host whose chat region the content renders; doubles
  /// as the panel's stream sink (the caller installs it on its run object).
  final TuiConversationHost host;

  /// The panel's `s` key: ask the caller's run to stop.
  final void Function() onStop;

  /// The panel's `x` key: close the panel through the caller's close path
  /// (which may drop run-specific hooks before the teardown below).
  final void Function() onClose;

  /// Settle the busy cue — the run finished, the comet stops sweeping.
  void setFinished() => frame.setBusy(false);
}

/// Owns run-panel construction: turns a [PanelSpec] into a live [OpenedPanel]
/// by composing the screen's regions, frames, and coordinators. The seam sits
/// one level ABOVE the `Panel`/`Region`/`Focusable` hierarchy (the
/// `tina_console` types are used as-is, never subclassed or altered here);
/// panel consumers obtain their panels through this host instead of
/// constructing concrete panels inline.
///
/// Built once with capability-scoped collaborators — no globals: everything
/// the open/close sequences touch is handed to the constructor.
class PanelHost {
  /// Creates the host. [makeSinkHost] is the spawned-host factory (detached
  /// chat region + inactive host, the panel's stream sink); [initialHost] is
  /// the primary conversation's host, whose `stayAttachedWhenInactive` flag
  /// the first-panel split / last-panel unsplit flips.
  PanelHost({
    required this.screen,
    required this.panelManager,
    required this.contentCoordinator,
    required this.resizeCoordinator,
    required this.tree,
    required this.initialHost,
    required TuiConversationHost Function(String conversationId) makeSinkHost,
  }) : _makeSinkHost = makeSinkHost;

  /// The screen panels render onto (and whose layout splits/unspilts).
  final Screen screen;
  final PanelManager panelManager;
  final ConversationPanelCoordinator contentCoordinator;
  final ResizeCoordinator resizeCoordinator;

  /// Spawn tree the panel registers its edge in (depth-1 under the root).
  final SpawnTree tree;

  /// The primary conversation's host: first-panel split sets
  /// `stayAttachedWhenInactive` (the chat stays visible beside the column),
  /// last-panel close clears it.
  final TuiConversationHost initialHost;

  final TuiConversationHost Function(String conversationId) _makeSinkHost;

  /// Open panels by conversation id, so a close can name its panel and a
  /// double close is a no-op.
  final Map<String, OpenedPanel> _panels = {};

  /// The open panel for [conversationId], if any.
  OpenedPanel? panelFor(String conversationId) => _panels[conversationId];

  /// Open the panel for [spec]. SYNCHRONOUS, and must stay so: the caller
  /// wires this into its launch path where [installSink] must run before any
  /// stream event can be delivered (the supervisor's `onLaunch` hook fires
  /// before the run's stream starts).
  OpenedPanel openPanel(
    PanelSpec spec, {
    required void Function(TuiConversationHost sinkHost) installSink,
    required void Function() onStop,
    required void Function() onClose,
  }) {
    // The panel's stream sink: a spawned-style host whose region renders in
    // this panel. Installed FIRST, before the split — the caller puts it
    // where streamed text should land from now on.
    final host = _makeSinkHost(spec.conversationId);
    installSink(host);

    // First panel: split the layout to make a right column (mirrors the
    // spawned-panel first-panel block). Read empty BEFORE adding — this is
    // the "is this the first panel" check. The canonical sequence lives in
    // [ResizeCoordinator.handleResize]; set stayAttachedWhenInactive first
    // (first-panel-specific), then repoint at it.
    if (!panelManager.hasSpawnedFrames) {
      initialHost.stayAttachedWhenInactive = true;
      resizeCoordinator.handleResize(split: true, drawInfoFrame: false);
    }

    final frame = PanelFrame(
      screen: screen,
      label: spec.label,
      conversationId: spec.conversationId,
      ownsCanvas: false,
    );
    // Depth-1 panel: parent is the root (no indent), and the clean label is
    // recorded so re-layout and label re-application see it.
    tree.parentOf[frame.conversationId] = tree.rootId;
    tree.baseLabel[frame.conversationId] = frame.label;
    final content = RunPanelContent(screen: screen, chat: host.chat);
    contentCoordinator.bindExtra(frame: frame, content: content);
    panelManager.layout();
    contentCoordinator.relayContent();

    // Scrollback: PgUp/PgDn + the mouse wheel scroll the transcript; the
    // frame badge shows lines that arrived while scrolled up (the same
    // wiring the conversation coordinator applies to chat panels).
    frame.onScroll = (deltaPages) {
      final page = host.chat.usableHeight;
      host.chat.scrollBy(deltaPages * (page > 0 ? page : 1));
    };
    frame.onWheel = (deltaRows) => host.chat.scrollBy(deltaRows);
    host.chat.onScrollbackChanged = () {
      frame.setScrollBadge(host.chat.newWhileScrolled);
    };

    final opened = OpenedPanel(
      frame: frame,
      content: content,
      host: host,
      onStop: onStop,
      onClose: onClose,
    );
    _panels[spec.conversationId] = opened;

    // Read-only like the environment panel (see
    // ConversationPanelCoordinator._wireReadOnlyInput): text keystrokes are
    // consumed with a one-time notice instead of falling through to the
    // shared editor, where they would silently type into the main
    // conversation. The panel's own keys (s/x) keep their meaning;
    // navigation passes through.
    var inputNoticeShown = false;
    frame.onPanelKey = (ev) {
      if (ev is CharInput && ev.text == 's') {
        opened.onStop();
        return true;
      }
      if (ev is CharInput && ev.text == 'x') {
        opened.onClose();
        return true;
      }
      final isText = ev is CharInput ||
          ev is PasteInput ||
          ev is EditingKey ||
          (ev is ControlKey && ev.code == ControlCode.enter);
      if (!isText) {
        // Arrows/PgUp/PgDn are not consumed here — PgUp/PgDn reach the
        // frame's scroll hook above; arrow keys do nothing (there is
        // nothing to pan). Esc/Ctrl+C/Alt also fall through to the editor.
        return false;
      }
      if (!inputNoticeShown) {
        inputNoticeShown = true;
        host.showMessage(
          '(input disabled — read-only run panel; s stops the run, x '
          'closes it; cycle focus back to a chat panel to type)\n',
          style: HostMessageStyle.dim,
        );
      }
      return true;
    };

    return opened;
  }

  /// Tear down the panel [handle] names, in the canonical order: frame hooks
  /// first (so a late event can't repaint a torn-down panel), then the chat
  /// scrollback hook, then content and registrations. When the last side
  /// panel goes away, unsplit back to the full-width primary (the mirror of
  /// the first-panel split); otherwise just re-tile the remaining column.
  void closePanel(OpenedPanel handle) {
    if (_panels[handle.frame.conversationId] != handle) return;
    _panels.remove(handle.frame.conversationId);
    // Drop the hooks first so a late event can't repaint a torn-down panel
    // (the frame is gone; its geometry is stale).
    handle.frame.onPanelKey = null;
    handle.frame.onScroll = null;
    handle.frame.onWheel = null;
    handle.host.chat.onScrollbackChanged = null;
    handle.content.detach();
    contentCoordinator.unbindExtra(handle.frame);
    tree.parentOf.remove(handle.frame.conversationId);
    tree.baseLabel.remove(handle.frame.conversationId);
    panelManager.removeFrame(handle.frame);
    if (!panelManager.hasSpawnedFrames) {
      // Last panel: unsplit back to the full-width primary (mirror of the
      // first-panel split).
      initialHost.stayAttachedWhenInactive = false;
      resizeCoordinator.handleResize(split: false, drawInfoFrame: true);
    } else {
      panelManager.layout();
      contentCoordinator.relayContent();
    }
    // The run continues streaming into the detached region until it ends;
    // the transcript buffers there and is discarded with the region.
  }
}

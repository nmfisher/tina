import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../host/tui_conversation_host.dart';
import 'panel_host.dart';
import 'run_panel_content.dart';

class OpenedRunPanel {
  OpenedRunPanel({
    required this.panel,
    required this.host,
    required this.onStop,
    required this.onClose,
  });

  /// The panel chrome (title, rails, busy cue, key dispatch).
  final OpenedPanel panel;
  PanelFrame get frame => panel.frame;

  /// The read-only transcript bound into the frame.
  RunPanelContent get content => panel.content as RunPanelContent;

  /// The spawned-style host whose chat region the content renders; doubles
  /// as the panel's stream sink (the caller installs it on its run object).
  final TuiConversationHost host;

  /// The panel's `s` key: ask the caller's run to stop.
  final void Function() onStop;

  /// The panel's `x` key: close the panel through the caller's close path
  /// (which may drop run-specific hooks before the teardown below).
  final void Function() onClose;

  /// Settle the busy cue — the run finished, the comet stops sweeping.
  void setFinished() => panel.setFinished();
}

/// Workflow transcript policy layered on the content-agnostic panel host.
/// Sink installation stays synchronous and precedes any layout or stream work.
class RunPanelHost {
  RunPanelHost({
    required this.panels,
    required TuiConversationHost Function(String id) makeSinkHost,
  }) : _makeSinkHost = makeSinkHost;

  final PanelHost panels;
  final TuiConversationHost Function(String id) _makeSinkHost;
  final Map<String, OpenedRunPanel> _panels = {};

  OpenedRunPanel? panelFor(String id) => _panels[id];

  OpenedRunPanel openPanel(
    PanelSpec spec, {
    required void Function(TuiConversationHost sinkHost) installSink,
    required void Function() onStop,
    required void Function() onClose,
  }) {
    panels.ensureAvailable(spec.id);
    final host = _makeSinkHost(spec.id);
    final content = RunPanelContent(screen: panels.screen, chat: host.chat);
    try {
      installSink(host);
    } catch (_) {
      content.detach();
      rethrow;
    }
    final panel = panels.openPanel(
      spec,
      content: content,
      inputMode: PanelInputMode.readOnly,
      onDispose: () {
        host.chat.onScrollbackChanged = null;
        _panels.remove(spec.id);
      },
    );
    final frame = panel.frame;
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

    final opened = OpenedRunPanel(
      panel: panel,
      host: host,
      onStop: onStop,
      onClose: onClose,
    );
    _panels[spec.id] = opened;

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
      final isText =
          ev is CharInput ||
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

  void closePanel(OpenedRunPanel handle) => panels.closePanel(handle.panel);
}

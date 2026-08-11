import 'package:tina_console/tina_console.dart';

/// The live view of one background workflow run, presented in a right-column
/// [PanelFrame] like a spawned agent panel. It is a **chat-style transcript of
/// the run**: for each node, `▶ <node>` / a dim node header / the node's full
/// task (user style) / the live streamed output + tool calls / `✔ <node>` —
/// streamed by the run's host into the wrapped [ScrollingTextRegion], exactly
/// as a conversation streams into its chat region. The bottom row carries a
/// dim "input disabled" label: the panel is read-only, so no editor is ever
/// bound to its frame.
///
/// The transcript adapter ([ChatRegionPanelContent]) owns the region's
/// positioning; this wrapper only reserves the bottom row for the label and
/// delegates the rest.
class RunPanelContent implements PanelContent {
  RunPanelContent({required this.screen, required this.chat})
      : _transcript = ChatRegionPanelContent(chat);

  final Screen screen;
  final ScrollingTextRegion chat;
  final ChatRegionPanelContent _transcript;

  Rect _interior = Rect.empty;

  // -- PanelContent --------------------------------------------------------

  @override
  bool get isDetached => _transcript.isDetached;

  @override
  BackendSurface? get surface => _transcript.surface;

  @override
  void bindSurface(BackendSurface? s) => _transcript.bindSurface(s);

  @override
  void fit(Rect interior, {required bool reserveInputRow}) {
    _interior = interior;
    // The transcript sits above the label row (the panel reserves no input
    // row — see bindExtra — so the content owns the full interior).
    if (interior.height >= 2) {
      _transcript.fit(
        Rect(
          row: interior.row,
          col: interior.col,
          width: interior.width,
          height: interior.height - 1,
        ),
        reserveInputRow: false,
      );
    }
    _paintLabel();
  }

  @override
  void attach() {
    _transcript.attach();
    _paintLabel();
  }

  @override
  void detach() => _transcript.detach();

  // -- Rendering -----------------------------------------------------------

  /// The dim read-only notice in the panel's bottom row. Plain-then-colorize
  /// so the fit never splits an SGR sequence.
  void _paintLabel() {
    final b = _interior;
    if (b.isEmpty || b.height < 1) return;
    const plain = 'input disabled — read-only workflow view';
    final text = plain.length <= b.width
        ? plain.padRight(b.width)
        : plain.substring(0, b.width);
    screen.putAtAbsolute(
      row: b.row + b.height - 1,
      col: b.col,
      text: screen.colorize(screen.theme.chat.dim, text),
      maxCols: b.width,
      moveCursor: false,
      clipRect: b,
    );
  }
}

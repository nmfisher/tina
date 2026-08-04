/// Raw-mode console toolkit for Dart CLI programs.
///
/// Built around [Screen], the sole owner of stdout and ANSI escapes. The
/// terminal is divided into [Region]s (chat, status, input, overlays) that
/// clip every write to their bounds. Frame borders are repainted
/// automatically after any write that could have touched them, so callers
/// never invoke "repair" sequences directly.
///
/// Supporting pieces:
/// - [LineEditor]: async raw-mode editor that renders into [InputRegion].
/// - [Spinner] (a no-op; turn-animation retired) / [ProgressCounter]: overlays
///   in [StatusRegion].
/// - [CompletionPicker]: `@`-triggered popup, an [OverlayRegion].
/// - [ConfirmDialog]: Ctrl-C confirmation box, an [OverlayRegion].
/// - [CompletionProvider]: pluggable source of picker suggestions.
/// - [fuzzyScore] / [rankFuzzy]: subsequence-fuzzy ranking helpers.
library;

export 'src/backend/backend_factory.dart';
export 'src/backend/backend_surface.dart';
export 'src/backend/input_backend.dart';
export 'src/backend/notcurses_probe.dart';
export 'src/backend/terminal_backend.dart';
export 'src/ansi_capable.dart';
export 'src/ansi_wrap.dart';
export 'package:fuzzy_ranker/fuzzy_ranker.dart';
export 'src/completion_picker.dart';
export 'src/comet.dart';
export 'src/confirm_dialog.dart';
export 'src/focusable.dart';
export 'src/focus_manager.dart';
export 'src/info_panel.dart';
export 'src/input_event.dart';
export 'src/input_parser.dart';
export 'src/text_line_input.dart';
export 'src/line_editor.dart';
export 'src/line_layout.dart';
export 'src/menu.dart';
export 'src/menu_bar.dart';
export 'src/modal_surface.dart';
export 'src/panel.dart';
export 'src/rect.dart';
export 'src/region.dart';
export 'src/conversation_panel.dart';
export 'src/panel_content.dart';
export 'src/screen.dart';
export 'src/screen_layout.dart';
export 'src/spinner.dart';
export 'src/stdio.dart';
export 'src/text_buffer.dart';
export 'src/text_panel.dart';
export 'src/terminal_bg.dart';
export 'src/theme.dart';
export 'src/tool_chip.dart';

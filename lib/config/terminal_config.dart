import 'package:tina_console/tina_console.dart';

enum BackendChoice { ansi, notcurses }

/// How spawned and sub-agent conversations are shown. [tiled] is the default:
/// the active conversation keeps the width and spawns appear beside it as
/// columns. [sidebar] additionally reserves a left column listing the
/// conversation tree — it costs 24 columns of transcript width, so it is off by
/// default, but it is fully supported and one flag away (`--layout sidebar`, or
/// `[tui] layout = "sidebar"` in `~/.tina/config`).
enum LayoutStyle { sidebar, tiled }

/// Frontend settings; never passed to agent or background execution.
class TerminalConfig {
  final BackendChoice backend;
  final Theme theme;
  final bool mouseWheel;
  final LayoutStyle layout;
  const TerminalConfig({
    this.backend = BackendChoice.notcurses,
    this.theme = const Theme.defaults(),
    this.mouseWheel = false,
    this.layout = LayoutStyle.tiled,
  });
}

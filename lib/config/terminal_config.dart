import 'package:tina_console/tina_console.dart';

enum BackendChoice { ansi, notcurses }

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
    this.layout = LayoutStyle.sidebar,
  });
}

/// tina_cli — the headless shell. It reads a line, runs one turn through
/// a tina_host session, and prints what happened: one line per tool call,
/// then the reply. The mode (`/mode`) is switched by calling the tools
/// plugin's handle directly — the host stays mode-blind. No TUI, no
/// persistence: this package's core takes an injected provider factory
/// and an injected writer, so tests drive it with no terminal.
library;

export 'src/shell_config.dart';

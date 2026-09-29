/// tina_tui — the TUI package: the full-screen front end, the headless
/// assembly it drives, and the widgets it renders with.
///
/// The assembly (`src/assembly.dart`) is front-end-free: it wires engine,
/// host, plugins and the session loop against an injected provider
/// factory and an [AssemblyWriter], so a daemon or a test can run the
/// whole app with no renderer initialised. The entry point
/// (`bin/tina_tui.dart`) is the terminal front end that drives it — the
/// only place a `Terminal` service is registered for real.
///
/// Exposed here:
/// - [TuiAssembly], `AssemblyOptions`, [AssemblyWriter],
///   [SinkAssemblyWriter] — the app, buildable and drivable headless;
/// - [TuiSession] — the front end's wrapper: the assembly with the TUI's
///   terminal in the slot;
/// - [configModelReference], `loadTinaConfig`, `TinaConfigError`,
///   `TinaConfigFile` — the config reader the entry point calls first;
/// - [providerForDescriptor], [builtinDescriptors], [descriptorByIdFor] —
///   the descriptor table and the seam a test factory overrides;
/// - [listSessions] — a plain session listing for embedding hosts;
/// - the TUI pieces: terminal, command dispatch, approval dialog and
///   approver, the render loop ([runApp]), chat/stream/tool-chip/status
///   views, and the input line's completion sources ([runApp] wires
///   them; [CommandNameCompletionSource] and [GitFileCompletionSource]
///   are the two).
library;

export 'src/app.dart';
export 'src/approval_approver.dart';
export 'src/approval_dialog.dart';
export 'src/assembly.dart';
export 'src/assembly_config.dart';
export 'src/configured_provider.dart';
export 'src/config_document.dart';
export 'src/settings_panel.dart';
export 'src/chat_view.dart';
export 'src/completion_sources.dart';
export 'src/status_strip.dart';
export 'src/stream_view.dart';
export 'src/tool_chip_view.dart';
export 'src/tui_commands.dart';
export 'src/tui_session.dart';
export 'src/tui_terminal.dart';

export 'src/plugin_catalog.dart' show TuiPluginContext;

export 'src/plugin_settings.dart';

export 'src/cli.dart';
export 'src/shell_completion.dart';

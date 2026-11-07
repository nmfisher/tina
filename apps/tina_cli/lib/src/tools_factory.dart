/// The tools plugin the assembly constructs, behind a seam (stage 5,
/// engine-on-wasm): the native assembly builds the full `ToolsPlugin`
/// (sandbox layout, process runners, approvals store); a wasm
/// composition root injects a portable implementation over the WASI
/// filesystem and the `tina:process` host import. The wiring record is
/// platform-neutral on purpose — what the assembly knows, nothing more.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/mode.dart' show PermissionMode;
import 'package:tina_settings/tina_settings.dart';

import 'tools_factory_unsupported.dart'
    if (dart.library.io) 'tools_factory_io.dart';

/// Everything the assembly knows when it builds the tools plugin.
final class ToolsWiring {
  const ToolsWiring({
    required this.workspaceRoot,
    required this.tinaDirPath,
    required this.protectedPaths,
    required this.osSandbox,
    required this.mode,
    this.settings,
  });

  final String workspaceRoot;
  final String tinaDirPath;
  final List<String> protectedPaths;
  final bool osSandbox;
  final PermissionMode mode;
  final ScopedSettings? settings;
}

/// Builds the tools plugin for [wiring].
typedef ToolsPluginFactory = AgentPlugin Function(ToolsWiring wiring);

ToolsPluginFactory? _injected;

/// The wasm composition root's factory; null means the platform default.
set injectedToolsPluginFactory(ToolsPluginFactory factory) =>
    _injected = factory;

/// The tools plugin for [wiring]: the injected factory when a
/// composition root set one, else the native full plugin.
AgentPlugin buildToolsPlugin(ToolsWiring wiring) =>
    (_injected ?? nativeToolsPluginFactory)(wiring);

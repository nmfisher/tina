/// The tools plugin the assembly constructs, behind a seam (stage 5,
/// engine-on-wasm): the native assembly builds the full `ToolsPlugin`
/// (sandbox layout, process runners, approvals store); a wasm
/// composition root injects a portable implementation over the WASI
/// filesystem and the `tina:process` host import. The wiring record is
/// platform-neutral on purpose — what the assembly knows, nothing more.
library;

import 'package:tina_capability/tina_capability.dart';
import 'package:tina_mode/mode.dart' show PermissionMode;
import 'package:tina_settings/tina_settings.dart';

import 'native_kinds.dart';
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
    this.capabilities,
  });

  final String workspaceRoot;
  final String tinaDirPath;
  final List<String> protectedPaths;
  final bool osSandbox;
  final PermissionMode mode;
  final ScopedSettings? settings;

  /// The compiled capability document (one source of truth): on native it
  /// seeds the enforcement inputs; under wasm the host enforces it and
  /// the portable factory ignores it.
  final CapabilityDocument? capabilities;
}

/// Builds the tools plugin for [wiring].
typedef ToolsPluginFactory = ToolsPlugin Function(ToolsWiring wiring);

ToolsPluginFactory? _injected;

/// The wasm composition root's factory; null means the platform default.
set injectedToolsPluginFactory(ToolsPluginFactory factory) =>
    _injected = factory;

/// The tools plugin for [wiring]: the injected factory when a
/// composition root set one, else the native full plugin.
ToolsPlugin buildToolsPlugin(ToolsWiring wiring) =>
    (_injected ?? nativeToolsPluginFactory)(wiring);

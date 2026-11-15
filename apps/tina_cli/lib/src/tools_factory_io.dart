import 'dart:io' as io;

import 'package:tina_tools/tina_tools.dart' show ToolsPlugin;

import 'tools_factory.dart';

/// The native tools factory: the full `ToolsPlugin`, exactly as the
/// assembly constructed it before the seam existed.
ToolsPluginFactory get nativeToolsPluginFactory => (wiring) => ToolsPlugin(
      workspaceRoot: wiring.workspaceRoot,
      tinaDir: io.Directory(wiring.tinaDirPath),
      protectedPaths: wiring.protectedPaths,
      osSandbox: wiring.osSandbox,
      settings: wiring.settings,
      mode: wiring.mode,
      capabilities: wiring.capabilities,
    );

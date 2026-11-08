
import 'tools_factory.dart';

/// The no-`dart:io` tools factory: a wasm composition root must inject
/// one ([injectedToolsPluginFactory]) before the assembly boots.
ToolsPluginFactory get nativeToolsPluginFactory => (wiring) =>
    throw UnsupportedError(
        'no native tools plugin on this platform: inject a factory');

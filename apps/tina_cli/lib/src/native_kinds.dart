/// The assembly's native plugin/backend kinds, conditionally resolved:
/// the real `ToolsPlugin` and `ConfigSettingsBackend` where `dart:io`
/// exists; clean aliases (the engine's plugin base, the settings
/// interface) under wasm, where a composition root injects portable
/// implementations of the same contracts.
library;

export 'native_kinds_unsupported.dart'
    if (dart.library.io) 'native_kinds_io.dart';

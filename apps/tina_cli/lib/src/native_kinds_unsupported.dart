import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';

/// Under wasm the native kinds do not exist; the aliases name the clean
/// supertypes so one assembly compiles on both platforms.
typedef ToolsPlugin = AgentPlugin;
typedef ConfigSettingsBackend = SettingsBackend;

/// The store types under wasm (no sqlite): shape-only aliases.
typedef SessionStore = Object;
typedef SessionStoreOpener = Object Function();

import 'package:tina_persistence/session_store_api.dart' as store_api;
import 'package:tina_tools/portable_tools.dart' show ToolsPluginSurface;

import 'settings_surface.dart';

/// Under wasm the native kinds do not exist; the aliases name the clean
/// portable surfaces so one assembly compiles on both platforms and
/// every view (analyzer conditional included) resolves the same members
/// the CI-named tests drive.
typedef ToolsPlugin = ToolsPluginSurface;
typedef ConfigSettingsBackend = ConfigSettingsSurface;

/// The store types under wasm: the portable contract (the sqlite store
/// implements it natively; the wasm engine's JSONL store does too).
typedef SessionStore = store_api.SessionStoreApi;
typedef SessionStoreOpener = store_api.SessionStoreOpener;

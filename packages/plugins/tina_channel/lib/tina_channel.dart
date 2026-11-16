/// tina_channel — the in-tina group channel: the store contract every
/// consumer depends on (tools, CLI, TUI pane), the pure-Dart
/// implementation, the agent tools and the session plugin. No sqlite
/// here; the native implementation lives in `tina_channel_sqlite.dart`.
library;

export 'channel_store_api.dart';
export 'src/channel_plugin.dart';
export 'src/channel_pane_plugin.dart';
export 'src/channel_tools.dart';
export 'src/in_memory_channel_store.dart';

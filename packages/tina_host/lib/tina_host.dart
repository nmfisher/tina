/// tina_host — the piece that assembles a session: one provider (built by
/// a factory, one per host) and the plugins from the config mounted on one
/// loop. No terminal anywhere in it; the TUI is a sibling. The host is
/// mode-blind: the permission mode belongs to the plugin that owns the
/// enforcement boundary.
library;

export 'src/compaction.dart';
export 'src/host.dart';
export 'src/host_config.dart';
export 'src/plugins.dart';
export 'src/session.dart';
export 'src/store.dart';

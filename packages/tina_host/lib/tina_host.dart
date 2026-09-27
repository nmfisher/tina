/// tina_host — the piece that assembles a session: one provider (built by
/// a factory, one per host), one sandboxed filesystem, the six tools, one
/// loop. No terminal anywhere in it; the TUI is a sibling.
library;

export 'src/host.dart';
export 'src/host_config.dart';
export 'src/plugins.dart';
export 'src/session.dart';
export 'src/tool_set.dart';

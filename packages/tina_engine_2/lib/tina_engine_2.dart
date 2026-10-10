/// tina_engine_2 — the agent loop and plugin interface, built on
/// tina_core's value types and streaming `LlmProvider`. Every host — the
/// TUI assembly, the headless runner, sub-agents — runs this loop.
library;

export 'src/context.dart';
export 'src/loop.dart';
export 'src/model.dart';
export 'src/plugin.dart';
export 'src/provider.dart';
export 'src/tee_provider.dart';

export 'package:tina_core/tina_core.dart';

export 'src/tool_execution.dart';

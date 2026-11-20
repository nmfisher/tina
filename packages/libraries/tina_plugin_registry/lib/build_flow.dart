/// The wasm-clean entry to the shared plugin build flow: the same
/// orchestration the main barrel serves ([PluginBuildFlow], its report
/// and the consent vocabulary) without the registry client's
/// `dart:io` closure. The wasm engine's plugin admin imports this path
/// because the engine composition must compile without `dart:io`;
/// native surfaces keep using `package:tina_plugin_registry/tina_plugin_registry.dart`.
library tina_plugin_registry.build_flow;

export 'src/build_flow.dart';

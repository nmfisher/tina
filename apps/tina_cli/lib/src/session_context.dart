/// The assembly's plugin context, shared by the full native registry and
/// the portable registry a wasm composition root builds (stage 5,
/// engine-on-wasm). No plugin imports here: this file must compile where
/// `dart:io` and the terminal-only plugins cannot.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart' show ProviderFactory;
import 'package:tina_session_controls/tina_session_controls.dart'
    show ModelCatalog;
import 'package:tina_providers/tina_providers.dart'
    show ProviderPolicyPlugin, RequestLimits;
import 'package:tina_settings/tina_settings.dart';

/// Explicit dependencies available to factories in the application
/// assembly. Split from `plugin_catalog.dart` (stage 5, engine-on-wasm):
/// the catalog imports every first-party plugin, including the
/// terminal-only ones a wasm composition root cannot compile; the
/// context itself has no such dependency.
///
/// [tools] is the tools plugin the assembly constructed — the full
/// `ToolsPlugin` natively, a portable implementation under wasm — typed
/// as the engine's plugin base: the capability machinery resolves the
/// tools policy from the plugin instance, never from this field.
final class SessionPluginContext {
  const SessionPluginContext({
    required this.workingDirectory,
    required this.terminal,
    required this.tools,
    required this.providerFactory,
    required this.model,
    required this.currentModel,
    required this.switchModel,
    required this.modelCatalog,
    this.currentReasoning,
    this.setReasoning,
    this.reasoningChoices,
    this.openStore,
    this.sessionStorePath,
    this.version = '0.0.0',
    this.restart,
    this.providerPolicy,
    required this.configPath,
    this.limits = const RequestLimits(),
    this.settings,
    this.readLimits,
    this.contextLoaded,
  });
  final String workingDirectory;
  final String configPath;
  final String version;
  final void Function(String)? restart;
  final ProviderPolicyPlugin? providerPolicy;
  final RequestLimits limits;
  final ScopedSettings? settings;
  final RequestLimits Function()? readLimits;
  final bool Function()? contextLoaded;
  RequestLimits get currentLimits => readLimits?.call() ?? limits;
  final Terminal terminal;
  final AgentPlugin tools;
  final ProviderFactory providerFactory;
  final String model;
  final String Function() currentModel;
  final void Function(String) switchModel;
  final ModelCatalog Function() modelCatalog;

  /// The conversation's reasoning effort ('auto' = no override), or null when
  /// the entry point has no settings stack. Null disables /reasoning.
  final String? Function()? currentReasoning;

  /// Persist the reasoning choice for this conversation. Null disables it.
  final void Function(String)? setReasoning;

  /// Effort words the current model accepts. Null means the canonical set.
  final List<String> Function()? reasoningChoices;
  /// The persistence opener (a `SessionStore Function()`), untyped here so
  /// this file compiles without the store's sqlite dependency; the
  /// persistence plugin's factory casts it.
  final Object? openStore;
  final String? sessionStorePath;
}

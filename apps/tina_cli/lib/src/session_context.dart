/// The assembly's plugin context, shared by the full native registry and
/// the portable registry a wasm composition root builds (stage 5,
/// engine-on-wasm). No plugin imports here: this file must compile where
/// `dart:io` and the terminal-only plugins cannot.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart' show ProviderFactory;
import 'package:tina_session_controls/tina_session_controls.dart'
    show ModelCatalog, ProfileList;
import 'package:tina_memory/tina_memory.dart' show AnswerCacheStats;
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
    this.currentContextWindow,
    this.currentReasoning,
    this.setReasoning,
    this.reasoningChoices,
    this.subagentModel,
    this.approverModel,
    this.profiles,
    this.switchProfile,
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
    this.memoryCacheStats,
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

  /// The session's live answer-cache scoreboard for /memory stats, or
  /// null when no memory plugin is attached. Read lazily — the plugin
  /// exists once the assembly has started.
  final AnswerCacheStats? Function()? memoryCacheStats;
  RequestLimits get currentLimits => readLimits?.call() ?? limits;
  final Terminal terminal;
  final AgentPlugin tools;
  final ProviderFactory providerFactory;
  final String model;
  final String Function() currentModel;
  final void Function(String) switchModel;
  final ModelCatalog Function() modelCatalog;

  /// The active model's context window in tokens, resolved live from
  /// the descriptor registry (the models.dev-corrected descriptors the
  /// assembly holds), or null when the reference resolves to no
  /// descriptor model. Consumers degrade to their safe fixed defaults
  /// on null — absence never throws. Untyped int keeps this file free
  /// of the descriptor packages, as [modelCatalog] keeps it free of
  /// their picker types.
  final int? Function()? currentContextWindow;

  /// The conversation's reasoning effort ('auto' = no override), or null when
  /// the entry point has no settings stack. Null disables /reasoning.
  final String? Function()? currentReasoning;

  /// Persist the reasoning choice for this conversation. Null disables it.
  final void Function(String)? setReasoning;

  /// Effort words the current model accepts. Null means the canonical set.
  final List<String> Function()? reasoningChoices;

  /// The active profile's effective subagent leg (`provider/model`), or
  /// null when children inherit the parent's current model at spawn.
  /// Read at spawn; null keeps the long-standing behavior.
  final String? Function()? subagentModel;

  /// The active profile's effective approver leg (`provider/model`), or
  /// null when the legacy classifier chain applies (the deprecated
  /// classifier model override, then the conversation's model).
  final String? Function()? approverModel;

  /// The config's profile presets and the active name, for /profile, the
  /// connection picker and snapshot publication. Null when this
  /// composition has no profile surface.
  final ProfileList Function()? profiles;

  /// Copy a named profile's legs into this conversation's current values.
  /// Throws on an unknown name.
  final void Function(String profile)? switchProfile;
  /// The persistence opener (a `SessionStore Function()`), untyped here so
  /// this file compiles without the store's sqlite dependency; the
  /// persistence plugin's factory casts it.
  final Object? openStore;
  final String? sessionStorePath;

  /// The typed capability view of this session's plugin payloads
  /// (commit 28): the first payload that implements [T], or null when
  /// this session has none. Plugins declare capabilities by
  /// implementing them; consumers query — absence is a first-class
  /// answer, and consumers degrade (skip or notice the limitation),
  /// never cast. Payloads are scanned in the assembly's resolution
  /// order (tools first), so a capability with several holders resolves
  /// deterministically to the one the assembly wired.
  T? capability<T extends Object>() {
    final tools = this.tools;
    if (tools is T) return tools as T; // guarded: never throws
    final policy = providerPolicy;
    if (policy is T) return policy as T; // guarded: never throws
    return null;
  }
}

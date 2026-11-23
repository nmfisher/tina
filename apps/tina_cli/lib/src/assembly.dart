library;

import 'dart:async';
import 'dart:convert';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_memory/tina_memory.dart' show MemoryPlugin;
import 'package:tina_session_controls/tina_session_controls.dart'
    show ModelCatalog, ProfileList, reasoningSetting;
import 'package:tina_providers/tina_providers.dart'
    show
        ModelProfile,
        ProfileLeg,
        activeProfileSetting,
        effectiveProfileLeg,
        effectiveProfileName,
        profileApproverModelSetting,
        profileMainModelSetting,
        profileSubagentModelSetting;
import 'session_terminal.dart';
import 'package:tina_mode/mode.dart' show PermissionMode;
import 'package:path/path.dart' as p;

import 'app_io.dart';
import 'native_kinds.dart';
import 'package:tina_tools/portable_tools.dart' show ToolsPluginSurface;
import 'app_stdout.dart';
import 'assembly_config.dart';
import 'configured_provider.dart';
import 'provider_default.dart';
import 'session_context.dart';
import 'plugin_settings.dart';
import 'tools_factory.dart';
import 'persistence_seam.dart';
import 'package:tina_settings/tina_settings.dart';
import 'settings_catalog.dart';
import 'settings_stack.dart';
import 'config_document.dart';
import 'snapshot_catalog.dart';

/// Optional instrumentation of the real startup path. Callbacks must not
/// mutate the assembly. No extra config or store reads are made for profiling.
final class AssemblyDiagnostics {
  const AssemblyDiagnostics({this.stage, this.modelEvent, this.ready});
  final void Function(String name)? stage;
  final void Function(StreamEvent event)? modelEvent;
  final void Function(SessionAssembly assembly)? ready;
}

/// Where an entry point's lines go. One seam for everything the
/// assembly itself prints; injectable so a test captures it.
abstract interface class AssemblyWriter {
  void writeln([String? line]);
}

/// A writer over any [StringSink]s — a StringBuffer in tests.
final class SinkAssemblyWriter implements AssemblyWriter {
  /// Everything the assembly says goes to [out]; [err] is unused today but
  /// exists so a future split does not change the seam.
  SinkAssemblyWriter({StringSink? out, StringSink? err})
      : out = out ?? StringBuffer(),
        err = err ?? StringBuffer();

  final StringSink out;
  final StringSink err;

  @override
  void writeln([String? line]) => out.writeln(line ?? '');
}

/// The process's stdout and stderr. The one place the app writes a bare
/// line outside the full-screen loop: a session listing, which
/// runs before any screen exists.
final class StdoutAssemblyWriter implements AssemblyWriter {
  const StdoutAssemblyWriter();

  @override
  void writeln([String? line]) {
    appStdoutWriteln(line ?? '');
  }
}

/// What the session was asked to run with: everything [SessionAssembly.start]
/// needs. No argument parsing here — the entry point owns its own flags
/// and maps them onto this.
final class AssemblyOptions {
  const AssemblyOptions({
    this.configPath,
    this.workingDirectory,
    this.storePath,
    this.sessionId,
    this.onRestart,
    this.plugins,
    this.approvalChannel,
    this.version = '0.0.0',
    this.model,
    this.profile,
    this.osSandbox = true,
    this.yolo = false,
    this.interactive = true,
    this.registry,
    this.settingsBackend,
  });

  /// Explicit config file, else `~/.tina/config`.
  final String? configPath;

  /// The session's working directory, else the process's cwd.
  final String? workingDirectory;

  /// Override the persistence plugin's default workspace store location.
  /// Persistence is enabled or disabled through the selected plugins.
  final String? storePath;

  /// Resume this session id instead of starting fresh. Requires persistence;
  /// [storePath] is optional. New entries continue the restored log.
  final String? sessionId;

  final void Function(String bundleRoot, String? sessionId)? onRestart;

  /// Embedding override; otherwise the global config selects feature plugins.
  final List<String>? plugins;

  /// Selected channel plugin; defaults to the global config.
  final String? approvalChannel;
  final String version;
  final String? model;

  /// Run under this named profile (the `--profile` launch switch).
  /// Null follows the config's `profile` key (or the session's saved
  /// profile on resume). Like [model], a launch override is not persisted.
  final String? profile;

  /// Per-launch OS confinement. Permission policy remains active when false.
  final bool osSandbox;

  /// Authorize requested capabilities at launch (yolo mode). This
  /// is a launch-time override only; it is not persisted or selectable via
  /// /mode. OS sandbox and network remain governed by [osSandbox].
  final bool yolo;

  /// Ordinary questions may wait for attached clients only in interactive runs.
  final bool interactive;

  /// The plugin registry the assembly builds from. Null is the platform
  /// default (every first-party plugin natively); a wasm composition root
  /// injects the portable subset.
  final PluginRegistry<SessionPluginContext>? registry;

  /// The settings backend. Null is the platform default (the filesystem
  /// adapter); a wasm composition root injects a preloaded snapshot.
  final SettingsBackend? settingsBackend;
}

/// Default store stays separate from legacy session files and is scoped to
/// the workspace. The global config controls whether the plugin is loaded.
String defaultSessionStorePath(String workingDirectory) =>
    '$workingDirectory/.tina/sessions.db';

/// List a store's sessions, one line each: id, entry count, title. It
/// opens, reads the registry rows, closes, and never builds a session.
/// A store that cannot be opened throws; the entry point turns that into
/// its own error line.
void listSessions({
  required AssemblyWriter writer,
  required String storePath,
}) {
  if (!defaultAppIo().exists(storePath)) {
    persistenceNoStore(storePath);
  }
  persistenceListSessions(writer, storePath);
}

/// Build the provider for [model] off [descriptor]: the wire picks the
/// class, everything else comes off the descriptor. Endpoint and
/// credentials come from the environment, as `tina_llm` already does —
/// nothing here reads, holds, or prints a token.
LlmProvider providerForDescriptor(
    ProviderDescriptor? descriptor, String model) {
  if (descriptor == null) {
    // No provider named: the Anthropic wire, whose endpoint and token come
    // from the environment. The engine reads neither directly any more, so
    // this composition root supplies the I/O: the native ports, or a wasm
    // composition root's endpoint over `tina:http`.
    final io = defaultAppIo();
    final base =
        io.env('TINA_LLM_ENDPOINT') ?? 'https://api.z.ai/api/anthropic';
    return AnthropicProvider(
        model: model,
        endpoint: defaultHttpEndpoint(base),
        environment: AppIoEnvironmentPort(io));
  }
  return configuredProvider(
      TinaConfig(
          providerId: descriptor.id, model: model, descriptors: [descriptor]),
      model);
}

/// Assembles the host and concrete plugins with explicit dependencies.
/// The default terminal buffers output without opening a physical terminal.
final class SessionAssembly {
  SessionAssembly._({
    required this.host,
    required this.workingDirectory,
    required this.terminal,
    required this.writer,
    required this.configNote,
    required Map<String, dynamic> theme,
    required this.tools,
    required this.configPath,
    required this.descriptors,
    required this.validatePlugins,
    required this.pluginSettings,
    required this.pluginManager,
    required this.settings,
    required this.settingsBackend,
    required this.newSession,
    required this.applySavedConfiguration,
    required void Function() stopConfigurationUpdates,
  })  : _stopConfigurationUpdates = stopConfigurationUpdates,
        _theme = theme,
        commands = host.commands;

  final Host host;

  /// The session's working directory (the workspace permissions and
  /// stores are keyed by).
  final String workingDirectory;
  final PluginSettings<SessionPluginContext> pluginSettings;
  final PluginManager<SessionPluginContext> pluginManager;
  final ScopedSettings settings;
  /// The settings backend: the native filesystem adapter, or a
  /// composition root's injected backend (`native_kinds.dart` resolves
  /// which).
  final ConfigSettingsBackend settingsBackend;
  final _settingsListeners = <Object, void Function()>{};
  void Function() listenSettings(void Function() listener) {
    final owner = Object();
    _settingsListeners[owner] = listener;
    return () => _settingsListeners.remove(owner);
  }

  void _settingsChanged() {
    host.refreshSnapshot();
    for (final item in _settingsListeners.entries.toList()) {
      if (!_settingsListeners.containsKey(item.key)) continue;
      try {
        item.value();
      } catch (_) {
        _settingsListeners.remove(item.key);
      }
    }
  }

  final String configPath;
  final List<ProviderDescriptor> descriptors;
  final void Function(Iterable<String>) validatePlugins;
  final void Function() applySavedConfiguration;
  final void Function() _stopConfigurationUpdates;

  /// Tools expose mode/status to the frontend; approvals are loader-injected.
  /// The full plugin natively; a portable plugin under wasm. Typed as
  /// the portable surface (commit 28) — the payload every leg shares,
  /// never one concrete class.
  final ToolsPluginSurface tools;

  /// The typed capability query over the assembly-resolved payloads
  /// (commit 28), same contract as the session context's: the first
  /// payload that implements [T], or null. Consumers degrade on
  /// absence — never a payload cast.
  T? capability<T extends Object>() {
    final tools = this.tools;
    if (tools is T) return tools as T; // guarded: never throws
    return null;
  }

  /// Shared output supplied to the command plugins and the frontend.
  final Terminal terminal;

  final AssemblyWriter writer;

  /// The config status line read at start (never printed by the
  /// assembly — a front end decides whether a banner shows it).
  final String? configNote;
  Map<String, dynamic> _theme;
  Map<String, dynamic> get theme => _theme;

  /// The session's published commands.
  final Commands commands;

  var _quit = false;
  final SessionAssembly Function(String? model) newSession;

  /// Transient model output for the active foreground turn. Background
  /// requests and child providers do not feed the conversation renderer.
  Object? _turnObservation;
  int? _turnListener;
  bool get watchingTurn => host.session.loop.inTurn;

  static SessionAssembly start({
    AssemblyWriter writer = const _NullWriter(),
    ProviderFactory? providerFactory,
    Terminal? terminal,
    AssemblyOptions options = const AssemblyOptions(),
    List<ProviderDescriptor>? descriptors,
    void Function(PluginRegistry<SessionPluginContext>)? registerPlugins,
    AssemblyDiagnostics? diagnostics,
  }) =>
      _start(
          writer: writer,
          providerFactory: providerFactory,
          terminal: terminal,
          options: options,
          descriptors: descriptors,
          registerPlugins: registerPlugins,
          diagnostics: diagnostics,
          configurationUpdates: _ConfigurationUpdates());

  static SessionAssembly _start({
    required _ConfigurationUpdates configurationUpdates,
    required AssemblyWriter writer,
    ProviderFactory? providerFactory,
    Terminal? terminal,
    required AssemblyOptions options,
    List<ProviderDescriptor>? descriptors,
    void Function(PluginRegistry<SessionPluginContext>)? registerPlugins,
    AssemblyDiagnostics? diagnostics,
  }) {
    diagnostics?.stage?.call('assembly-start');
    descriptors ??= configuredDescriptors();
    diagnostics?.stage?.call('descriptors-ready');
    final config =
        loadTinaConfig(path: options.configPath, descriptors: descriptors);
    diagnostics?.stage?.call('config-loaded');
    // A malformed config must not silently re-enable persistence or other
    // defaults the user may have explicitly disabled.
    if (config is TinaConfigProblem) throw FormatException(config.problem);
    var resolved = config.config;
    var model = options.model ??
        (providerFactory == null
            ? resolved.mainModelReference
            : resolved.model);
    if (providerFactory == null && options.model != null) {
      model = canonicalModelReference(resolved, model);
    }
    final workingDirectory =
        options.workingDirectory ?? defaultAppIo().currentDirectory;
    final output = terminal ??
        SessionTerminal(
            questions: SessionQuestions(interactive: options.interactive));
    final registry = options.registry ?? ScopedSettingsStack.defaultPluginRegistry();
    registerPlugins?.call(registry);
    final stack = ScopedSettingsStack.build(
        globalPath: options.configPath ?? defaultConfigPath(),
        workspacePath: '$workingDirectory/.tina/config',
        registry: registry,
        descriptors: descriptors,
        config: resolved,
        onConfigurationChanged: configurationUpdates.changed,
        backend: options.settingsBackend);
    final pluginSettings = PluginSettings<SessionPluginContext>(
      globalPath: options.configPath ?? defaultConfigPath(),
      workspacePath: '$workingDirectory/.tina/config',
      registry: registry,
      descriptors: descriptors,
      sessionBaseline: options.plugins,
      channelOverride: options.approvalChannel,
    );
    final catalog = stack.catalog;
    final settingsBackend = stack.backend;
    final settings = stack.settings;
    // Declared before the profile helpers below: switching a profile
    // re-points this assembly's future requests.
    SessionAssembly? assembled;
    resolved = ConfigDocument.validateValues(
        stack.effectiveDocument(),
        descriptors: descriptors);
    // A launch profile is a run override: it must name a preset the config
    // defines (the config's own key is validated at load).
    if (options.profile != null &&
        !resolved.profiles.containsKey(options.profile)) {
      final names = resolved.profiles.keys.toList()..sort();
      throw FormatException('no profile named "${options.profile}"'
          '${names.isEmpty ? '' : ' — choices: ${names.join(', ')}'}');
    }
    // The run's active profile: --profile wins for the run, then a profile
    // switched in this conversation (restored on resume), then the config
    // file's key. Read through a closure: saved configuration can change it.
    ModelProfile? activeProfile() => resolved.profiles[effectiveProfileName(
        launchProfile: options.profile,
        settings: settings,
        configProfile: resolved.profile)];
    ProfileList profileList() {
      final names = resolved.profiles.keys.toList()..sort();
      return ProfileList(
        active: effectiveProfileName(
            launchProfile: options.profile,
            settings: settings,
            configProfile: resolved.profile),
        names: names,
        legs: {
          for (final name in names)
            name: {
              for (final leg in ProfileLeg.values)
                if (resolved.profiles[name]!
                        .legReference(leg,
                            sessionProvider:
                                resolved.providerId ?? 'anthropic')
                    case final ref?)
                  leg.name: ref,
            },
        },
      );
    }

    /// Switching copies the profile's legs into the current values —
    /// profiles are presets, the legs are the truth. Subagent/approver
    /// legs land as session-scoped settings (cleared when the profile
    /// leaves the leg unset), the main leg re-points future requests like
    /// /model. A profile that omits the main leg keeps the conversation's
    /// current model.
    void switchSessionProfile(String name) {
      final profile = resolved.profiles[name];
      if (profile == null) throw ArgumentError('no profile named "$name"');
      final provider = resolved.providerId ?? 'anthropic';
      final values = <String, Object?>{activeProfileSetting.id: name};
      final remove = <String>{};
      void copy(SettingDefinition<String> setting, ProfileLeg leg) {
        final ref =
            profile.legReference(leg, sessionProvider: provider)?.trim();
        if (ref == null || ref.isEmpty) {
          remove.add(setting.id);
        } else {
          values[setting.id] = ref;
        }
      }

      copy(profileSubagentModelSetting, ProfileLeg.subagent);
      copy(profileApproverModelSetting, ProfileLeg.approver);
      settings.update(SettingScope.session, values, remove: remove);
      final main =
          profile.legReference(ProfileLeg.main, sessionProvider: provider);
      if (main != null) {
        assembled?.host.switchModel(providerFactory == null
            ? canonicalModelReference(resolved, main)
            : main);
      }
    }

    model = options.model ??
        (providerFactory == null
            ? (effectiveProfileLeg(
                        profileMainModelSetting,
                        settings,
                        activeProfile(),
                        ProfileLeg.main,
                        sessionProvider: resolved.providerId ?? 'anthropic') ??
                    resolved.mainModelReference)
            : resolved.model);
    if (providerFactory == null && options.model != null) {
      model = canonicalModelReference(resolved, model);
    }
    final tools = buildToolsPlugin(ToolsWiring(
      workspaceRoot: workingDirectory,
      tinaDirPath: '$workingDirectory/.tina',
      protectedPaths: [
        options.configPath ?? defaultConfigPath(),
        if (options.storePath case final String customStore) ...[
          customStore,
          '$customStore-wal',
          '$customStore-shm',
          '$customStore-journal',
        ],
        if (stack.protectedPermissionsPath case final String protected)
          protected,
      ],
      osSandbox: options.osSandbox,
      settings: settings,
      pathApprovalDirectory: stack.protectedPermissionsPath,
      mode: options.yolo ? PermissionMode.yolo : PermissionMode.approve,
    ));
    diagnostics?.stage?.call('settings-and-tools-ready');
    final policy = configuredPolicy(resolved,
        override: providerFactory, currentConfig: () => resolved);
    final enabled = pluginSettings.features;
    final selected = pluginSettings.selected;
    registry.validate(selected);
    final persists = enabled.contains('tina/persistence');
    if (!persists && (options.storePath != null || options.sessionId != null)) {
      throw ArgumentError('--store and --resume require tina/persistence');
    }
    final path = options.storePath ?? defaultSessionStorePath(workingDirectory);
    SessionStore openStore() {
      diagnostics?.stage?.call('store-open-start');
      defaultAppIo().createDirectory(p.dirname(path), recursive: true);
      final store = persistenceOpenStore(path) as SessionStore;
      diagnostics?.stage?.call('store-open-end');
      return store;
    }

    if (options.sessionId != null) {
      final stored = openStore();
      try {
        diagnostics?.stage?.call('settings-replay-start');
        restoreSessionSettings(
            settings, stored, options.sessionId!);
        diagnostics?.stage?.call('settings-replay-end');
        resolved = ConfigDocument.validateValues(
            stack.effectiveDocument(),
            descriptors: descriptors);
        policy.updateLimits(resolved.limits);
        pluginSettings.restoreSessionOverrides({
          for (final id in registry.ids)
            if (settings.layer(SettingScope.session)['$id/enabled']
                case final bool enabled)
              id: enabled,
        });
        if (options.model == null && options.profile == null)
          model = storedSessionModel(stored, options.sessionId!) ?? model;
      } finally {
        closeStore(stored);
      }
    }
    final context = SessionPluginContext(
      sessionStorePath: path,
      configPath: options.configPath ?? defaultConfigPath(),
      workingDirectory: workingDirectory,
      terminal: output,
      tools: tools,
      providerFactory: policy.childProvider,
      providerPolicy: policy,
      limits: resolved.limits,
      settings: settings,
      readLimits: () => resolved.limits,
      version: options.version,
      restart: options.onRestart == null
          ? null
          : (root) {
              final current = assembled!;
              final saved = sessionWasPersisted(
                  current.host.plugins, current.host.session.id);
              options.onRestart!(root, saved ? current.host.session.id : null);
              current._quit = true;
            },
      model: model,
      currentModel: () => assembled?.host.model ?? model,
      switchModel: (next) => assembled!.host.switchModel(providerFactory == null
          ? canonicalModelReference(resolved, next)
          : next),
      currentReasoning: () {
        // The session override first; without one the effective config value
        // (any scope) or the provider default — reported as 'auto'.
        final resolvedEffort = resolved.reasoningEffort;
        final setting = settings.read(reasoningSetting);
        if (setting.source == SettingScope.session) return setting.value;
        return resolvedEffort ?? 'auto';
      },
      setReasoning: (word) {
        // A session-scoped write: validated against the full effective config
        // by the backend, persisted only for this conversation, and picked up
        // by the next request's provider rebuild. 'auto' removes the override
        // so the configured value applies again.
        settings.update(
            SettingScope.session,
            word == 'auto'
                ? const {}
                : {reasoningSetting.id: reasoningSetting.encode(word)},
            remove: word == 'auto' ? {reasoningSetting.id} : const {});
        resolved = ConfigDocument.validateValues(
            stack.effectiveDocument(),
            descriptors: descriptors);
        policy.updateLimits(resolved.limits);
      },
      reasoningChoices: () {
        // Offer what the current model accepts on its wire; the canonical
        // set is the fallback when the model is unknown to a descriptor.
        final reference = assembled?.host.model ?? model;
        final slash = reference.indexOf('/');
        final wireModel = slash < 0 ? reference : reference.substring(slash + 1);
        final choices = thinkingChoicesFor(wireModel);
        return choices;
      },
      subagentModel: () => effectiveProfileLeg(
          profileSubagentModelSetting,
          settings,
          activeProfile(),
          ProfileLeg.subagent,
          sessionProvider: resolved.providerId ?? 'anthropic'),
      approverModel: () => effectiveProfileLeg(
          profileApproverModelSetting,
          settings,
          activeProfile(),
          ProfileLeg.approver,
          sessionProvider: resolved.providerId ?? 'anthropic'),
      profiles: profileList,
      switchProfile: switchSessionProfile,
      // The active model's context window, live: the current reference
      // resolved against the assembly's descriptors — the same list the
      // config reloads refresh, so a models.dev correction or a /model
      // switch is honored on the next read. The reference may be bare
      // (the injected-factory leg keeps the wire model name), so a
      // prefix-less name falls back to the config's provider, then the
      // anthropic default — the same chain configuredProvider uses.
      // Null when nothing resolves; the compaction plugin falls back to
      // its safe fixed default.
      currentContextWindow: () {
        final reference = assembled?.host.model ?? model;
        final slash = reference.indexOf('/');
        final providerId = slash > 0
            ? reference.substring(0, slash)
            : (resolved.providerId ?? 'anthropic');
        final wireModel =
            slash > 0 ? reference.substring(slash + 1) : reference;
        return descriptorByIdFor(providerId, resolved.descriptors)
            ?.models[wireModel]
            ?.contextWindow;
      },
      // The connection-controls catalog rides the shared modelCatalogChoices
      // rule (the settings editor's picker list) over the resolved config:
      // configured providers plus the active provider, the anthropic
      // default for provider-less configs, the conversation model's
      // provider, and the current ref kept pickable.
      modelCatalog: () {
        final current = assembled?.host.model ?? model;
        final choices = modelCatalogChoices(
            entries: [
              for (final descriptor in resolved.descriptors)
                if (resolved.providers.containsKey(descriptor.id) ||
                    descriptor.id == resolved.providerId ||
                    (resolved.providers.isEmpty &&
                        descriptor.id == 'anthropic') ||
                    current.startsWith('${descriptor.id}/'))
                  ModelCatalogEntry(
                      id: descriptor.id,
                      name: descriptor.name,
                      models: {
                        for (final model in descriptor.models.values)
                          model.id: model.name,
                      }),
            ],
            providerNames: {
              for (final descriptor in resolved.descriptors)
                descriptor.id: descriptor.name,
            },
            disabled: {
              for (final entry in resolved.providers.entries)
                entry.key: entry.value.disabledModels,
            },
            current: current);
        return ModelCatalog(
            models: choices?.refs ?? const [],
            providerNames: choices?.providerNames ?? const {},
            modelNames: choices?.modelNames ?? const {});
      },
      openStore: persists ? openStore : null,
      contextLoaded: () =>
          assembled?.host.plugins
              .any((plugin) => plugin.id == 'tina/context') ??
          false,
      // The live scoreboard /memory stats shows: read at command time
      // from the assembled host's memory plugin (absent when the
      // session selection has no memory — stats then says so).
      memoryCacheStats: () => assembled?.host.plugins
          .whereType<MemoryPlugin>()
          .firstOrNull
          ?.answerCache?.stats,
    );
    final plugins = registry.build(pluginSettings.selected, context);
    final factory = plugins.whereType<ModelAccess>().single.mainProvider;
    final hostConfig = HostConfig(
      notices: output is SessionTerminal ? output.notices : null,
      skippedPlugins: pluginSettings.skippedPluginIds,
      snapshotFeatureFor: snapshotFeatureFor,
      operationsFor: (plugin) => registry.definition(plugin.id).operations,
      questions: output is SessionTerminal
          ? output.questions
          : SessionQuestions(interactive: options.interactive),
      providerFactory: (model) => _ObservedProvider(factory(model), () {
        diagnostics?.stage?.call('provider-send');
        final current = assembled;
        if (current == null || !current.host.session.loop.inTurn) return null;
        final loop = current.host.session.loop;
        final turn = current._turnObservation;
        return (event) {
          if (loop.inTurn && identical(turn, current._turnObservation)) {
            for (final observer
                in current.host.plugins.whereType<WatchObserver>()) {
              try {
                observer.watch(event);
              } catch (_) {}
            }
          }
        };
      }, diagnostics?.modelEvent),
      model: model,
      restoreModel: options.model == null && options.profile == null,
      workingDirectory: workingDirectory,
      plugins: plugins,
    );
    diagnostics?.stage?.call('host-open-start');
    final host = options.sessionId == null
        ? Host.start(hostConfig)
        : Host.resume(hostConfig, options.sessionId!);
    diagnostics?.stage?.call('host-open-end');
    // Unknown enabled plugins were skipped at boot (graceful degradation
    // for a packaged binary whose registry is a subset of a native
    // checkout): surface the skip on the notice channel so the user sees
    // what the config asked for and the binary left out.
    if (pluginSettings.skippedPluginIds.isNotEmpty) {
      host.notices.write(
        'Skipped unknown plugins (not in this binary): '
        '${pluginSettings.skippedPluginIds.join(', ')}',
      );
    }
    var previousConfiguration = jsonEncode(stack.effectiveDocument());
    final stopConfigurationUpdates = configurationUpdates.listen(() {
      try {
        final values = stack.effectiveDocument();
        final encoded = jsonEncode(values);
        settings.reload();
        // Persisted layers can change while session overrides keep the
        // effective configuration identical. Refresh scope metadata anyway.
        pluginSettings.reload();
        pluginSettings.restoreSessionOverrides({
          for (final id in registry.ids)
            if (settings.layer(SettingScope.session)['$id/enabled']
                case final bool enabled)
              id: enabled,
        });
        if (encoded == previousConfiguration) return;
        final next =
            ConfigDocument.validateValues(values, descriptors: descriptors);
        refreshProviderDefinitions(catalog, next);
        settings.reload();
        resolved = next;
        previousConfiguration = encoded;
        policy.updateLimits(next.limits);
        policy.refreshConfiguration();
        assembled?._theme = next.theme;
        assembled?.pluginManager.select(pluginSettings.selected);
        settings.applicationErrors.remove('configuration');
        assembled?._settingsChanged();
      } catch (_) {
        settings.applicationErrors['configuration'] =
            'Saved configuration could not be applied; check Settings.';
      }
    });
    final assembly = SessionAssembly._(
      host: host,
      workingDirectory: workingDirectory,
      terminal: output,
      writer: writer,
      configNote: config.note,
      theme: resolved.theme,
      tools: tools,
      configPath: options.configPath ?? defaultConfigPath(),
      descriptors: descriptors,
      validatePlugins: registry.validate,
      pluginSettings: pluginSettings,
      settings: settings,
      settingsBackend: settingsBackend,
      pluginManager:
          PluginManager(host: host, registry: registry, context: context),
      stopConfigurationUpdates: stopConfigurationUpdates,
      applySavedConfiguration: () {
        final saved =
            loadTinaConfig(path: options.configPath, descriptors: descriptors);
        if (saved is TinaConfigProblem) throw FormatException(saved.problem);
        configurationUpdates.changed();
      },
      newSession: (model) => SessionAssembly._start(
          configurationUpdates: configurationUpdates,
          writer: writer,
          providerFactory: providerFactory,
          descriptors: descriptors,
          registerPlugins: registerPlugins,
          diagnostics: diagnostics,
          options: AssemblyOptions(
              configPath: options.configPath,
              onRestart: options.onRestart,
              osSandbox: options.osSandbox,
              interactive: options.interactive,
              workingDirectory: workingDirectory,
              storePath: options.storePath,
              plugins: options.plugins,
              approvalChannel: options.approvalChannel,
              version: options.version,
              model: model,
              profile: options.profile)),
    );
    assembled = assembly;
    // Built-ins are the assembly's, registered by the assembly — the
    // same registry, the same dispatch.
    assembly._turnListener = host.session.loop.subscribe((entry, event) {
      if (entry is TurnStartedEntry) assembly._turnObservation = Object();
      if (entry is TurnEndedEntry || entry is ContextClearedEntry)
        assembly._turnObservation = null;
    });
    host.commands.publish(Command(
      name: 'quit',
      description: 'leave the app',
      allowWhileRunning: true,
      handler: (_) {
        assembly._quit = true;
      },
    ));
    host.commands.publish(Command(
      name: 'settings',
      description: 'edit session, workspace and global settings',
      allowWhileRunning: true,
      handler: (_) async {
        output.writeln(
            'Settings requires the interactive TUI. Edit ${assembly.configPath}.');
      },
    ));
    host.commands.publish(Command(
      name: 'help',
      description: 'list loaded commands and input keys',
      handler: (_) {
        for (final c in host.commands.all) {
          output.writeln('/${c.name} — ${c.description}');
        }
        output.writeln(
            'Type while busy and Enter to queue. Ctrl+C clears the draft; with an empty draft it quits. Esc cancels active work and preserves the draft, including while a dialog is open. Tab completes command arguments; @ completes files.');
        output.writeln(
            'Scroll conversation: Option/Alt+Up/Down moves one displayed line; Page Up/Down moves a page. Plain Up/Down recalls input history. Drag past a chat edge to scroll a text selection; release to copy, Esc to cancel.');
      },
    ));
    diagnostics?.stage?.call('assembly-ready');
    diagnostics?.ready?.call(assembly);
    return assembly;
  }

  /// True once `/quit` has been dispatched. A front end's loop reads
  /// this after each command; the assembly has no loop of its own.
  bool get quitRequested => _quit;

  /// Dispatch one `/word` or registered prefix alias through the registry:
  /// a published command
  /// runs its handler (which reports through whatever [Terminal] is in
  /// the slot), an unpublished word is refused. Returns false when the
  /// front end should stop ([quitRequested] after `/quit`). An empty or
  /// non-command line is nothing to this method.
  Future<bool> handleCommand(String line) async {
    final connection = host.connect();
    try {
      if (!line.trimLeft().startsWith('/') &&
          connection.commandFor(line) == null) return true;
      final result = await connection.submit(line);
      if (result.notice case final notice?) writer.writeln(notice);
      return !_quit;
    } finally {
      connection.close();
    }
  }

  /// Owner shutdown drains all accepted host operations before releasing the
  /// provider, plugin stores and configuration subscriptions.
  Future<void> shutdown() async {
    final stopped = host.shutdown();
    final output = terminal;
    if (output is SessionTerminal) output.closeInput();
    try {
      await stopped;
    } finally {
      close();
    }
  }

  /// Close an idle assembly; active work requires [shutdown].
  void close() {
    if (_turnListener case final listener?)
      host.session.loop.unsubscribe(listener);
    _turnListener = null;
    _turnObservation = null;
    _settingsListeners.clear();
    _stopConfigurationUpdates();
    try {
      host.close();
    } finally {
      settings.close();
    }
  }
}

/// Panels share saved global provider changes without sharing session state.
final class _ConfigurationUpdates {
  final _listeners = <void Function()>{};
  Timer? _timer;
  void Function() listen(void Function() listener) {
    _listeners.add(listener);
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => changed());
    return () {
      _listeners.remove(listener);
      if (_listeners.isEmpty) {
        _timer?.cancel();
        _timer = null;
      }
    };
  }

  void changed() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}

/// The assembly's writer when nobody handed one in: nowhere. Tests and
/// the full-screen app both pass a real one.
final class _NullWriter implements AssemblyWriter {
  const _NullWriter();

  @override
  void writeln([String? line]) {}
}

/// Capture an observer per request. Background summaries/judgments stay quiet,
/// and a cancelled request cannot paint into a later turn.
final class _ObservedProvider implements LlmProvider {
  _ObservedProvider(this.inner, this.observer, [this.modelEvent]);
  final LlmProvider inner;
  final WatchSink? Function() observer;
  final void Function(StreamEvent)? modelEvent;
  @override
  String get model => inner.model;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final stream = TeeProvider(inner, sink: observer())
        .send(system: system, messages: messages, tools: tools);
    final observe = modelEvent;
    if (observe == null) return stream;
    return stream.map((event) {
      observe(event);
      return event;
    });
  }

  @override
  void close() => inner.close();
}

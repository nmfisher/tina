library;

import 'dart:io' show Directory, File, stdout;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart' show ModelCatalog;
import 'tui_terminal.dart';
import 'package:tina_tools/tina_tools.dart' show ToolsPlugin;

import 'assembly_config.dart';
import 'configured_provider.dart';
import 'plugin_catalog.dart';
import 'plugin_settings.dart';
import 'package:tina_persistence/tina_persistence.dart';

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
    stdout.writeln(line ?? '');
  }
}

/// What the session was asked to run with: everything [TuiAssembly.start]
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
    this.osSandbox = true,
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

  /// Per-launch OS confinement. Permission policy remains active when false.
  final bool osSandbox;
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
  if (!File(storePath).existsSync()) {
    throw SessionStoreException('no session store at $storePath');
  }
  final store = SessionStore.open(storePath);
  try {
    final sessions = store.list();
    if (sessions.isEmpty) {
      writer.writeln('no sessions in $storePath');
      return;
    }
    for (final s in sessions) {
      writer.writeln('${s.id}  ${s.entries} entries'
          '${s.title == null ? '' : '  ${s.title}'}');
    }
  } finally {
    store.close();
  }
}

/// Build the provider for [model] off [descriptor]: the wire picks the
/// class, everything else comes off the descriptor. Endpoint and
/// credentials come from the environment, as `tina_llm` already does —
/// nothing here reads, holds, or prints a token.
LlmProvider providerForDescriptor(
    ProviderDescriptor? descriptor, String model) {
  if (descriptor == null) {
    // No provider named: the Anthropic wire, whose provider reads
    // TINA_LLM_ENDPOINT / TINA_LLM_TOKEN itself.
    return AnthropicProvider(model: model);
  }
  return configuredProvider(
      TinaConfig(
          providerId: descriptor.id, model: model, descriptors: [descriptor]),
      model);
}

/// Assembles the host and concrete plugins with explicit dependencies.
/// The default terminal buffers output without opening a physical terminal.
final class TuiAssembly {
  TuiAssembly._({
    required this.host,
    required this.terminal,
    required this.writer,
    required this.configNote,
    required this.theme,
    required this.tools,
    required this.configPath,
    required this.descriptors,
    required this.validatePlugins,
    required this.pluginSettings,
    required this.pluginManager,
    required this.newSession,
    required this.applySavedConfiguration,
    required void Function() stopConfigurationUpdates,
  })  : _stopConfigurationUpdates = stopConfigurationUpdates,
        commands = host.commands;

  final Host host;
  final PluginSettings<TuiPluginContext> pluginSettings;
  final PluginManager<TuiPluginContext> pluginManager;
  final String configPath;
  final List<ProviderDescriptor> descriptors;
  final void Function(Iterable<String>) validatePlugins;
  Future<void> Function()? openSettings;
  final void Function() applySavedConfiguration;
  final void Function() _stopConfigurationUpdates;

  /// Tools expose mode/status to the frontend; approvals are loader-injected.
  final ToolsPlugin tools;

  /// Shared output supplied to the command plugins and the frontend.
  final Terminal terminal;

  final AssemblyWriter writer;

  /// The config status line read at start (never printed by the
  /// assembly — a front end decides whether a banner shows it).
  final String? configNote;
  final Map<String, dynamic> theme;

  /// The session's published commands.
  final Commands commands;

  var _quit = false;
  final TuiAssembly Function(String? model) newSession;

  /// Transient model output for the active foreground turn. Background
  /// requests and child providers do not feed the conversation renderer.
  WatchSink? onWatch;
  Object? turnObservation;
  bool get watchingTurn => turnObservation != null;

  static TuiAssembly start({
    AssemblyWriter writer = const _NullWriter(),
    ProviderFactory? providerFactory,
    Terminal? terminal,
    AssemblyOptions options = const AssemblyOptions(),
    List<ProviderDescriptor>? descriptors,
    void Function(PluginRegistry<TuiPluginContext>)? registerPlugins,
  }) =>
      _start(
          writer: writer,
          providerFactory: providerFactory,
          terminal: terminal,
          options: options,
          descriptors: descriptors,
          registerPlugins: registerPlugins,
          configurationUpdates: _ConfigurationUpdates());

  static TuiAssembly _start({
    required _ConfigurationUpdates configurationUpdates,
    required AssemblyWriter writer,
    ProviderFactory? providerFactory,
    Terminal? terminal,
    required AssemblyOptions options,
    List<ProviderDescriptor>? descriptors,
    void Function(PluginRegistry<TuiPluginContext>)? registerPlugins,
  }) {
    descriptors ??= configuredDescriptors();
    final config =
        loadTinaConfig(path: options.configPath, descriptors: descriptors);
    // A malformed config must not silently re-enable persistence or other
    // defaults the user may have explicitly disabled.
    if (config is TinaConfigProblem) throw FormatException(config.problem);
    var resolved = config.config;
    var model = options.model ??
        (providerFactory == null
            ? '${resolved.providerId ?? 'anthropic'}/${resolved.model}'
            : resolved.model);
    if (providerFactory == null && options.model != null) {
      model = canonicalModelReference(resolved, model);
    }
    final workingDirectory = options.workingDirectory ?? Directory.current.path;
    final output = terminal ?? TuiTerminal();
    final tools = ToolsPlugin(
      workspaceRoot: workingDirectory,
      tinaDir: Directory('$workingDirectory/.tina'),
      osSandbox: options.osSandbox,
    );
    final policy = configuredPolicy(resolved,
        override: providerFactory, currentConfig: () => resolved);
    final registry = firstPartyPlugins();
    registerPlugins?.call(registry);
    final pluginSettings = PluginSettings<TuiPluginContext>(
      globalPath: options.configPath ?? defaultConfigPath(),
      workspacePath: '$workingDirectory/.tina/config',
      registry: registry,
      descriptors: descriptors,
      sessionBaseline: options.plugins,
      channelOverride: options.approvalChannel,
    );
    final enabled = pluginSettings.features;
    final selected = pluginSettings.selected;
    registry.validate(selected);
    final persists = enabled.contains('tina/persistence');
    if (!persists && (options.storePath != null || options.sessionId != null)) {
      throw ArgumentError('--store and --resume require tina/persistence');
    }
    final path = options.storePath ?? defaultSessionStorePath(workingDirectory);
    SessionStore openStore() {
      File(path).parent.createSync(recursive: true);
      return SessionStore.open(path);
    }

    TuiAssembly? assembled;
    if (options.sessionId != null && options.model == null) {
      final stored = openStore();
      try {
        model =
            stored.list().singleWhere((s) => s.id == options.sessionId).model ??
                model;
      } finally {
        stored.close();
      }
    }
    final context = TuiPluginContext(
      configPath: options.configPath ?? defaultConfigPath(),
      workingDirectory: workingDirectory,
      terminal: output,
      tools: tools,
      providerFactory: policy.childProvider,
      providerPolicy: policy,
      limits: resolved.limits,
      version: options.version,
      restart: options.onRestart == null
          ? null
          : (root) {
              final current = assembled!;
              final saved = current.host.plugins
                  .whereType<PersistencePlugin>()
                  .any((plugin) => plugin.store
                      .list()
                      .any((row) => row.id == current.host.session.id));
              options.onRestart!(root, saved ? current.host.session.id : null);
              current._quit = true;
            },
      model: model,
      currentModel: () => assembled?.host.model ?? model,
      switchModel: (next) => assembled!.host.switchModel(providerFactory == null
          ? canonicalModelReference(resolved, next)
          : next),
      modelCatalog: () => ModelCatalog(models: [
        for (final descriptor in resolved.descriptors)
          if (resolved.providers.containsKey(descriptor.id) ||
              descriptor.id == resolved.providerId ||
              (resolved.providers.isEmpty && descriptor.id == 'anthropic') ||
              (assembled?.host.model ?? model).startsWith('${descriptor.id}/'))
            for (final name in descriptor.models.keys)
              if (!(resolved.providers[descriptor.id]?.disabledModels
                      .contains(name) ??
                  false))
                '${descriptor.id}/$name'
      ], providerNames: {
        for (final descriptor in resolved.descriptors)
          descriptor.id: descriptor.name,
      }, modelNames: {
        for (final descriptor in resolved.descriptors)
          for (final entry in descriptor.models.entries)
            '${descriptor.id}/${entry.key}': entry.value.name,
      }),
      openStore: persists ? openStore : null,
    );
    final plugins = registry.build(selected, context);
    final factory = plugins.whereType<ModelAccess>().single.mainProvider;
    final hostConfig = HostConfig(
      providerFactory: (model) => _ObservedProvider(factory(model), () {
        final current = assembled;
        if (current == null ||
            !current.watchingTurn ||
            !current.host.session.loop.inTurn) return null;
        final observation = current.turnObservation;
        return (event) {
          if (identical(observation, current.turnObservation)) {
            current.onWatch?.call(event);
            for (final observer
                in current.host.plugins.whereType<WatchObserver>()) {
              observer.watch(event);
            }
          }
        };
      }),
      model: model,
      restoreModel: options.model == null,
      workingDirectory: workingDirectory,
      plugins: plugins,
    );
    final host = options.sessionId == null
        ? Host.start(hostConfig)
        : Host.resume(hostConfig, options.sessionId!);
    final stopConfigurationUpdates = configurationUpdates.listen((next) {
      // The session keeps its selected model, budgets and presentation. Replace
      // the saved provider catalog and endpoint settings together, then let
      // running clients rebuild before their next request.
      resolved = TinaConfig(
          model: resolved.model,
          providerId: resolved.providerId,
          limits: resolved.limits,
          theme: resolved.theme,
          plugins: resolved.plugins,
          approvalChannel: resolved.approvalChannel,
          descriptors: next.descriptors,
          maxOutputTokens: next.maxOutputTokens,
          reasoningEffort: next.reasoningEffort,
          thinkingBudget: next.thinkingBudget,
          providers: next.providers);
      policy.refreshConfiguration();
    });
    final assembly = TuiAssembly._(
      host: host,
      terminal: output,
      writer: writer,
      configNote: config.note,
      theme: resolved.theme,
      tools: tools,
      configPath: options.configPath ?? defaultConfigPath(),
      descriptors: descriptors,
      validatePlugins: registry.validate,
      pluginSettings: pluginSettings,
      pluginManager:
          PluginManager(host: host, registry: registry, context: context),
      stopConfigurationUpdates: stopConfigurationUpdates,
      applySavedConfiguration: () {
        final saved =
            loadTinaConfig(path: options.configPath, descriptors: descriptors);
        if (saved is TinaConfigProblem) throw FormatException(saved.problem);
        configurationUpdates.apply(saved.config);
      },
      newSession: (model) => TuiAssembly._start(
          configurationUpdates: configurationUpdates,
          writer: writer,
          providerFactory: providerFactory,
          descriptors: descriptors,
          registerPlugins: registerPlugins,
          options: AssemblyOptions(
              configPath: options.configPath,
              onRestart: options.onRestart,
              osSandbox: options.osSandbox,
              workingDirectory: workingDirectory,
              storePath: options.storePath,
              plugins: pluginSettings.features,
              approvalChannel: pluginSettings.channel,
              version: options.version,
              model: model ?? host.model)),
    );
    assembled = assembly;
    // Built-ins are the assembly's, registered by the assembly — the
    // same registry, the same dispatch.
    host.commands.publish(Command(
      name: 'quit',
      description: 'leave the app',
      handler: (_) {
        assembly._quit = true;
      },
    ));
    host.commands.publish(Command(
      name: 'settings',
      description: 'edit global configuration',
      allowWhileRunning: true,
      handler: (_) async {
        final open = assembly.openSettings;
        if (open != null) {
          await open();
        } else {
          output.writeln(
              'Settings requires the interactive TUI. Edit ${assembly.configPath}.');
        }
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
            'Type while busy and Enter to queue. Esc clears the draft; Esc with an empty draft cancels. Tab completes command arguments; @ completes files.');
      },
    ));
    return assembly;
  }

  /// True once `/quit` has been dispatched. A front end's loop reads
  /// this after each command; the assembly has no loop of its own.
  bool get quitRequested => _quit;

  /// Dispatch one `/word` line through the registry: a published command
  /// runs its handler (which reports through whatever [Terminal] is in
  /// the slot), an unpublished word is refused. Returns false when the
  /// front end should stop ([quitRequested] after `/quit`). An empty or
  /// non-command line is nothing to this method.
  Future<bool> handleCommand(String line) async {
    final trimmed = line.trim();
    if (!trimmed.startsWith('/')) return true;
    final rest = trimmed.substring(1);
    final split = RegExp(r'\s').firstMatch(rest);
    final word = split == null ? rest : rest.substring(0, split.start);
    final argument = split == null ? '' : rest.substring(split.end).trim();
    final command = commands[word];
    if (command == null) {
      writer.writeln('unknown command: /$word');
      return true;
    }
    await command.handler(argument);
    return !_quit;
  }

  /// Close plugin resources and the session's provider through the host.
  void close() {
    _stopConfigurationUpdates();
    host.close();
  }
}

/// Panels share saved global provider changes without sharing session state.
final class _ConfigurationUpdates {
  final _listeners = <void Function(TinaConfig)>{};
  void Function() listen(void Function(TinaConfig) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void apply(TinaConfig config) {
    for (final listener in _listeners.toList()) {
      listener(config);
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
  _ObservedProvider(this.inner, this.observer);
  final LlmProvider inner;
  final WatchSink? Function() observer;
  @override
  String get model => inner.model;
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      TeeProvider(inner, sink: observer())
          .send(system: system, messages: messages, tools: tools);
  @override
  void close() => inner.close();
}

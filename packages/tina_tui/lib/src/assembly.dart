/// The session assembly: everything a front end needs to have a session —
/// the provider built from the config's choice, the host with the tools
/// plugin (which owns the mode), the shared services, and the session
/// itself. It owns no input loop and no renderer: it is usable with no
/// terminal at all (a daemon, a chat bridge), and the app drives it with
/// the TUI's terminal in the slot.
///
/// Three seams keep it testable with no terminal:
///
/// - **The provider factory is injected.** A test hands the scripted
///   provider over the same [ProviderFactory] seam production uses; the
///   assembly never knows which it got.
/// - **The writer is injected.** Everything the front end says — the
///   config note, a session listing — goes through one [AssemblyWriter],
///   so a test captures it into a string. Nothing here writes to stdout
///   itself.
/// - **Commands are a registry, not a switch.** The assembly publishes
///   the session's one built-in (`/quit`) and registers the mode command
///   plugin; what `/word` means is decided by whoever published it.
///
/// The mode path proves the layering: `/mode` is [ModeCommandPlugin]'s
/// command, published into the registry; the handler flips the
/// [ModeControl] the tools plugin published at mount and tells the
/// [Terminal]. The host is mode-blind; so is this file — no mode enum
/// is imported here.
library;

import 'dart:io' show Directory, File, Platform, stdout;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart' show ModeCommandPlugin, Approver;

import 'assembly_config.dart';

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
/// line outside the full-screen loop: the `--sessions` listing, which
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
  });

  /// Explicit config file, else `~/.tina/config`.
  final String? configPath;

  /// The session's working directory, else the process's cwd.
  final String? workingDirectory;

  /// The session store's file, when the session persists. Null keeps the
  /// session in memory.
  final String? storePath;

  /// Resume this session id instead of starting fresh. Requires
  /// [storePath]: the loop is seeded from the store's slice and new
  /// entries continue the same log.
  final String? sessionId;
}

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
  return switch (descriptor.wire) {
    ProviderWire.anthropic => AnthropicProvider(model: model),
    ProviderWire.openAiCompatible => OpenAiCompatibleProvider(
        model: model,
        baseUrl: descriptor.baseUrl,
        tokenFrom: () => Platform.environment[descriptor.keyEnvVar] ?? '',
      ),
    ProviderWire.gemini => GeminiProvider(
        model: model,
        baseUrl: descriptor.baseUrl,
        tokenFrom: () => Platform.environment[descriptor.keyEnvVar] ?? '',
      ),
  };
}

/// One assembled session: the host, the shared services, the terminal
/// the session's plugins talk to, the registry the loop dispatches
/// through, and the config it started from.
///
/// The terminal in the slot is whatever the front end registered — the
/// assembly builds none. `terminalOrNull` is null for a headless drive
/// (tests without a view, later a daemon): nothing in the assembly reads
/// the service, so a session runs, logs, and answers with no renderer
/// initialised. The one thing a headless session cannot do is ask — a
/// plugin that asks with no terminal in the slot gets the locator's
/// error, loudly, instead of a fake answer.
final class TuiAssembly {
  TuiAssembly._({
    required this.host,
    required this.services,
    required this.writer,
    required this.configNote,
    required this.tools,
  })  : commands = services.get<Commands>(),
        _modeCommand = ModeCommandPlugin(services);

  final Host host;

  /// The session's tools plugin — the boundary the approver answers to.
  /// Exposed so a front end can register its [Approver] after a
  /// headless build (the same write the [TuiAssembly.start] `approver`
  /// parameter performs at construction).
  final ToolsPlugin tools;

  /// The shared services: [Commands] always; [Terminal] when the front
  /// end registered one.
  final Services services;

  final AssemblyWriter writer;

  /// The config status line read at start (never printed by the
  /// assembly — a front end decides whether a banner shows it).
  final String? configNote;

  /// The session's published commands.
  final Commands commands;

  final ModeCommandPlugin _modeCommand;
  var _quit = false;

  /// Build the session: read the config, build the provider from the
  /// descriptor that matches, put the shared services (the [Terminal]
  /// only when the caller hands one in), build the host with the tools
  /// plugin (the boundary, publishing itself as the mode service), start
  /// or resume the one session, publish the built-in command, register
  /// the mode command plugin.
  ///
  /// [providerFactory] overrides the config-driven factory — the seam a
  /// test drives with the scripted provider.
  static TuiAssembly start({
    AssemblyWriter writer = const _NullWriter(),
    ProviderFactory? providerFactory,
    Terminal? terminal,
    Approver? approver,
    AssemblyOptions options = const AssemblyOptions(),
    List<ProviderDescriptor> descriptors = builtinDescriptors,
  }) {
    final config =
        loadTinaConfig(path: options.configPath, descriptors: descriptors);
    final resolved = config.config;
    final workingDirectory =
        options.workingDirectory ?? Directory.current.path;
    final services = Services();
    if (terminal != null) services.put<Terminal>(terminal);
    services.put<Commands>(Commands());
    final tools = ToolsPlugin(
      workspaceRoot: workingDirectory,
      tinaDir: Directory('$workingDirectory/.tina'),
      services: services,
    );
    if (approver != null) tools.sandbox.approver = approver;
    final hostConfig = HostConfig(
      providerFactory: providerFactory ??
          (model) => providerForDescriptor(
              descriptorByIdFor(resolved.providerId ?? '', descriptors),
              model),
      model: resolved.model,
      workingDirectory: workingDirectory,
      plugins: [tools],
      storePath: options.storePath,
    );
    final host = options.sessionId == null
        ? Host.start(hostConfig)
        : Host.resume(hostConfig, options.sessionId!);
    final assembly = TuiAssembly._(
      host: host,
      services: services,
      writer: writer,
      configNote: config.note,
      tools: tools,
    );
    // Built-ins are the assembly's, registered by the assembly — the
    // same registry, the same dispatch.
    services.get<Commands>().publish(Command(
          name: 'quit',
          description: 'leave the app',
          handler: (_) => assembly._quit = true,
        ));
    // The mode's word, owned by the plugin that carries it.
    assembly._modeCommand.register();
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
  bool handleCommand(String line) {
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
    command.handler(argument);
    return !_quit;
  }

  /// Close the host. The store link flushes; nothing else is held.
  void close() => host.close();
}

/// The assembly's writer when nobody handed one in: nowhere. Tests and
/// the full-screen app both pass a real one.
final class _NullWriter implements AssemblyWriter {
  const _NullWriter();

  @override
  void writeln([String? line]) {}
}

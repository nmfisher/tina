/// The shell itself: build the provider from the config's choice, build
/// the host with the tools plugin (which owns the mode) plus the mode
/// command plugin (which owns the word), start one session, and run the
/// read-line/run-turn/dispatch loop.
///
/// Three seams keep the core testable with no terminal:
///
/// - **The provider factory is injected.** A test hands the scripted
///   provider over the same [ProviderFactory] seam production uses; the
///   shell never knows which it got.
/// - **The writer is injected.** Everything the shell says — banner,
///   tool-call lines, replies, reasons — goes through one [ShellWriter],
///   so a test captures it into a string.
/// - **Commands are a registry, not a switch.** `/word` lines dispatch
///   through the session's [Commands]: a plugin's command runs the
///   plugin's handler, the shell never learns what a mode is. The
///   shell's own built-in (`/quit`) is registered the same way — the
///   difference is only that its handler flags the loop to stop.
///
/// The mode path proves the layering: `/mode` is [ModeCommandPlugin]'s
/// command, published into the registry; the handler flips the
/// [ModeControl] the tools plugin published at mount and tells the
/// [Terminal]. The host is mode-blind; so is this file — no mode enum
/// is imported here.
library;

import 'dart:async';
import 'dart:io' show Directory, Platform, stderr, stdout;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart' show ModeCommandPlugin;

import 'shell_config.dart';

/// Where the shell's lines go. One seam for everything printed;
/// injectable so a test captures it.
abstract interface class ShellWriter {
  void writeln([String? line]);
}

/// The terminal writer. Production's writer; tests substitute their own.
final class IoShellWriter implements ShellWriter {
  const IoShellWriter();

  @override
  void writeln([String? line]) {
    stdout.writeln(line ?? '');
  }
}

/// A writer over any [StringSink]s — a StringBuffer in tests.
final class SinkShellWriter implements ShellWriter {
  /// Everything the shell says goes to [out]; [err] is unused today but
  /// exists so a future split does not change the seam.
  SinkShellWriter({StringSink? out, StringSink? err})
      : out = out ?? StringBuffer(),
        err = err ?? StringBuffer();

  final StringSink out;
  final StringSink err;

  @override
  void writeln([String? line]) => out.writeln(line ?? '');
}

/// What the shell was asked to run with: everything [Shell.start] needs.
final class ShellOptions {
  const ShellOptions({
    this.configPath,
    this.workingDirectory,
  });

  /// Explicit config file, else `~/.tina/config`.
  final String? configPath;

  /// The session's working directory, else the process's cwd.
  final String? workingDirectory;
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

/// The [Terminal] the session's plugins see, over the shell's writer:
/// the same captured seam tests already hold, so a command's output
/// lands in the transcript. Asks go through the reader the REPL wires
/// up when it starts.
final class ShellTerminal implements Terminal {
  ShellTerminal(this._writer);

  final ShellWriter _writer;
  Future<String?> Function()? _read;

  /// Give [ask] its reader — the same line source the REPL reads.
  void wire(Future<String?> Function() read) => _read = read;

  @override
  void writeln([String? line]) => _writer.writeln(line);

  @override
  Future<String> ask(String prompt) async {
    _writer.writeln(prompt);
    final line = await (_read?.call() ?? Future<String?>.value(null));
    return line?.trim() ?? '';
  }
}

/// One shell session: the host, the shared services, the registry the
/// loop dispatches through.
final class Shell {
  Shell._({
    required this.host,
    required this.services,
    required this.terminal,
    required this.writer,
  })  : commands = services.get<Commands>(),
        _modeCommand = ModeCommandPlugin(services);

  final Host host;
  final Services services;
  final ShellTerminal terminal;
  final ShellWriter writer;

  /// The session's published commands — what the loop dispatches
  /// through and the greet line lists.
  final Commands commands;

  final ModeCommandPlugin _modeCommand;
  var _quit = false;

  /// Build a shell from [options]: read the config, build the provider
  /// from the descriptor that matches, build the host with the tools
  /// plugin (the boundary, publishing itself as the mode service) and
  /// the mode command plugin (the word), start the one session.
  /// [providerFactory] overrides the config-driven factory — the seam a
  /// test drives with the scripted provider.
  static Shell start({
    required ShellWriter writer,
    ProviderFactory? providerFactory,
    ShellOptions options = const ShellOptions(),
    List<ProviderDescriptor> descriptors = builtinDescriptors,
  }) {
    final config =
        loadShellConfig(path: options.configPath, descriptors: descriptors);
    final note = config.note;
    if (note != null) writer.writeln(note);
    final resolved = config.config;
    final workingDirectory =
        options.workingDirectory ?? Directory.current.path;
    final services = Services();
    final terminal = ShellTerminal(writer);
    services
      ..put<Terminal>(terminal)
      ..put<Commands>(Commands());
    final tools = ToolsPlugin(
      workspaceRoot: workingDirectory,
      tinaDir: Directory('$workingDirectory/.tina'),
      services: services,
    );
    final host = Host.start(
      HostConfig(
        providerFactory: providerFactory ??
            (model) => providerForDescriptor(
                descriptorByIdFor(resolved.providerId ?? '', descriptors),
                model),
        model: resolved.model,
        workingDirectory: workingDirectory,
        plugins: [tools],
      ),
    );
    final shell = Shell._(
      host: host,
      services: services,
      terminal: terminal,
      writer: writer,
    );
    // Built-ins are the shell's, registered by the shell — the same
    // registry, the same dispatch.
    services.get<Commands>().publish(Command(
          name: 'quit',
          description: 'leave the shell',
          handler: (_) => shell._quit = true,
        ));
    // The mode's word, owned by the plugin that carries it.
    shell._modeCommand.register();
    return shell;
  }

  /// The banner: who the shell is, which model it is pointed at, and
  /// the published commands.
  void greet() {
    writer.writeln(
        'tina shell — ${host.config.model}. '
        '${[for (final c in commands.all) '/${c.name} — ${c.description}'].join('; ')}.');
  }

  /// Run one entered line. Returns false when the loop should stop
  /// (`/quit`, or end of input). An empty line is ignored — no turn.
  ///
  /// A `/word` line dispatches through the registry: a published
  /// command runs its handler (which reports through the terminal);
  /// an unpublished word is refused by the shell. A turn that ends in
  /// error or cancellation prints the reason the outcome carries and
  /// keeps going; nothing throws out of here.
  Future<bool> handle(String? line) async {
    final trimmed = line?.trim() ?? '';
    if (trimmed.isEmpty) return true;
    if (trimmed.startsWith('/')) {
      final rest = trimmed.substring(1);
      final split = RegExp(r'\s').firstMatch(rest);
      final word = split == null ? rest : rest.substring(0, split.start);
      final argument =
          split == null ? '' : rest.substring(split.end).trim();
      final command = commands[word];
      if (command == null) {
        writer.writeln('unknown command: /$word');
        return true;
      }
      command.handler(argument);
      return !_quit;
    }
    await runTurn(trimmed);
    return true;
  }

  /// One turn: send, print one line per tool call, print the reply (or
  /// the reason the turn stopped). The reply text comes from the
  /// outcome's detail; the tool-call lines come from the transcript the
  /// turn appended.
  Future<void> runTurn(String text) async {
    final Outcome outcome;
    try {
      outcome = await host.send(text);
    } catch (e) {
      // Nothing above should throw — the loop turns failures into
      // outcomes — but the shell must survive one regardless.
      writer.writeln('error: $e');
      return;
    }
    for (final line in toolCallLines(outcome)) {
      writer.writeln(line);
    }
    switch (outcome.stopReason) {
      case StopReason.complete:
        final reply = outcome.detail.isNotEmpty
            ? outcome.detail
            : (host.session.lastReply ?? '');
        writer.writeln(reply);
      case StopReason.cancelled:
      case StopReason.error:
        writer.writeln('${outcome.stopReason.name}: ${outcome.detail}');
    }
  }

  /// One line per tool call the turn made, in transcript order:
  /// `· bash → exit code: 0` or `· write ✗ denied: …`. The name comes
  /// from the transcript, the result from the paired result block, so
  /// this is what actually happened — not what the model said happened.
  List<String> toolCallLines(Outcome outcome) {
    final results = <String, (String, bool)>{};
    final lines = <String>[];
    for (final message in outcome.messages) {
      for (final block in message.content) {
        if (block is ToolUseBlock) {
          lines.add('· ${block.name}');
        } else if (block is ToolResultBlock) {
          results[block.toolUseId] = (block.content, block.isError);
        }
      }
    }
    // Second pass: append each result to its call line, pairing by id —
    // the loop guarantees every call has a result.
    final paired = <String>[];
    var i = 0;
    for (final message in outcome.messages) {
      for (final block in message.content) {
        if (block is ToolUseBlock) {
          final r = results[block.id];
          final mark = r == null
              ? ''
              : (r.$2 ? ' ✗ ${_oneLine(r.$1)}' : ' → ${_oneLine(r.$1)}');
          paired.add('${lines[i++]}$mark');
        }
      }
    }
    return paired;
  }

  /// A tool result on one line: first line only, hard-capped, so the
  /// per-call line stays a line. The cap is generous enough to see a
  /// refusal or an exit code, short enough not to be a transcript.
  static String _oneLine(String s) {
    var line = s.trim().split('\n').first.trim();
    if (line.length > 160) line = '${line.substring(0, 157)}…';
    return line;
  }
}

/// The REPL: greet, wire the terminal's asks to the same line source,
/// then read lines until `/quit` or end of input.
Future<void> runShell({
  required Shell shell,
  required Future<String?> Function() readLine,
}) async {
  shell.greet();
  shell.terminal.wire(readLine);
  while (true) {
    final line = await readLine();
    if (line == null) return; // end of input: exit cleanly
    if (!await shell.handle(line)) return;
  }
}

/// The stderr line a bare `tina` process writes when the environment is
/// unusable. Kept here so bin/ stays thin.
void shellFatal(String message) {
  stderr.writeln('tina: $message');
}

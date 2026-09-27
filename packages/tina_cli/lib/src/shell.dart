/// The shell itself: build the provider from the config's choice, build
/// the host with the tools plugin (which owns the mode), start one
/// session, and run the read-line/run-turn/print loop.
///
/// Two seams keep the core testable with no terminal:
///
/// - **The provider factory is injected.** A test hands the scripted
///   provider over the same [ProviderFactory] seam production uses; the
///   shell never knows which it got.
/// - **The writer is injected.** Everything the shell says — banner,
///   tool-call lines, replies, reasons — goes through one [ShellWriter],
///   so a test captures it into a string.
///
/// The mode path is the design being exercised: `/mode` calls the tools
/// plugin's [ToolsPlugin.setMode] directly. The host is mode-blind — it
/// never learns what the mode is — and the file system and process
/// runner read the value per call, so the next tool call obeys it.
library;

import 'dart:async';
import 'dart:io' show Directory, Platform, stderr, stdout;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tools/tina_tools.dart' show PermissionMode;

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
    this.mode = PermissionMode.normal,
  });

  /// Explicit config file, else `~/.tina/config`.
  final String? configPath;

  /// The session's working directory, else the process's cwd.
  final String? workingDirectory;

  /// The mode the tools plugin starts in. `/mode` changes it later.
  final PermissionMode mode;
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

/// One shell session: the host, and the tools plugin it was built around.
/// The plugin handle is kept here because `/mode` is the shell's call to
/// make — the host stays mode-blind.
final class Shell {
  Shell._({required this.host, required this.tools, required this.writer});

  final Host host;
  final ToolsPlugin tools;
  final ShellWriter writer;

  /// Build a shell from [options]: read the config, build the provider
  /// from the descriptor that matches, build the host with the tools
  /// plugin as its one plugin, start the one session. [providerFactory]
  /// overrides the config-driven factory — the seam a test drives with
  /// the scripted provider.
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
    final tools = ToolsPlugin(
      workspaceRoot: workingDirectory,
      tinaDir: Directory('$workingDirectory/.tina'),
      mode: options.mode,
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
    return Shell._(host: host, tools: tools, writer: writer);
  }

  /// The banner: who the shell is, which model it is pointed at, and the
  /// two commands.
  void greet() {
    writer.writeln('tina shell — ${host.config.model}. '
        '/mode [normal|read-only] switches the permission mode; '
        '/quit leaves.');
  }

  /// Run one entered line. Returns false when the loop should stop
  /// (`/quit`, or end of input). An empty line is ignored — no turn.
  ///
  /// A turn that ends in error or cancellation prints the reason the
  /// outcome carries and keeps going; nothing throws out of here.
  Future<bool> handle(String? line) async {
    final trimmed = line?.trim() ?? '';
    if (trimmed.isEmpty) return true;
    if (trimmed == '/quit') return false;
    if (trimmed == '/mode') {
      _printMode();
      return true;
    }
    if (trimmed == '/mode normal' || trimmed == '/mode read-only') {
      final mode = trimmed.endsWith('read-only')
          ? PermissionMode.readOnly
          : PermissionMode.normal;
      // The whole point: the shell holds the plugin it built, so it
      // calls the handle directly. The host never learns what the mode
      // is; the next tool call simply obeys.
      tools.setMode(mode);
      writer.writeln('mode: ${mode == PermissionMode.readOnly
          ? 'read-only' : 'normal'}');
      return true;
    }
    if (trimmed.startsWith('/mode')) {
      writer.writeln("usage: /mode [normal|read-only] — now: ${_modeName()}");
      return true;
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

  void _printMode() => writer.writeln('mode: ${_modeName()}');

  String _modeName() => tools.mode == PermissionMode.readOnly
      ? 'read-only'
      : 'normal';

  /// A tool result on one line: first line only, hard-capped, so the
  /// per-call line stays a line. The cap is generous enough to see a
  /// refusal or an exit code, short enough not to be a transcript.
  static String _oneLine(String s) {
    var line = s.trim().split('\n').first.trim();
    if (line.length > 160) line = '${line.substring(0, 157)}…';
    return line;
  }
}

/// The REPL: greet, then read lines until `/quit` or end of input.
/// [readLine] supplies the next line — stdin in production, a fixed
/// script in tests.
Future<void> runShell({
  required Shell shell,
  required Future<String?> Function() readLine,
}) async {
  shell.greet();
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

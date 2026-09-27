// The shell, driven headless: the scripted provider plays the model, a
// StringBuffer captures everything the shell says. Covers line handling
// (empty, /quit, /mode through the registry), a full turn with its
// per-call line, and the mode switch reaching the model as a refusal on
// the next write call.
//
// Run: dart test
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_cli/tina_cli.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tools/tina_tools.dart'
    show ModeCommandPlugin, ModeControl;

/// A captured writer: every line the shell said, joined.
final class CapturedWriter implements ShellWriter {
  final StringBuffer buf = StringBuffer();

  @override
  void writeln([String? line]) => buf.writeln(line ?? '');

  /// Everything written, as one string.
  String get text => buf.toString();

  /// The lines written, without their trailing newlines.
  List<String> get lines =>
      const LineSplitter().convert(text.trimRight());
}

/// A shell over a temp workspace whose provider plays [script].
({Shell shell, CapturedWriter writer, ScriptedProvider provider})
    _shell(List<List<StreamEvent>> script) {
  final ws = Directory.systemTemp.createTempSync('tina_cli_ws_');
  addTearDown(() => ws.deleteSync(recursive: true));
  final writer = CapturedWriter();
  final provider = ScriptedProvider(script);
  final shell = Shell.start(
    writer: writer,
    providerFactory: (_) => provider,
    options: ShellOptions(
      configPath: '/nonexistent/tina/config',
      workingDirectory: ws.path,
    ),
  );
  return (shell: shell, writer: writer, provider: provider);
}

void main() {
  group('line handling', () {
    test('an empty line is ignored — no turn, no output', () async {
      final env = _shell([
        scriptedReply('should not run'),
      ]);
      final again = await env.shell.handle('   ');
      expect(again, isTrue, reason: 'the loop keeps going');
      expect(env.writer.text, isEmpty);
      expect(env.provider.callCount, 0, reason: 'no turn for an empty line');
    });

    test('/quit ends the loop', () async {
      final env = _shell([]);
      final again = await env.shell.handle('/quit');
      expect(again, isFalse);
      expect(env.writer.text, isEmpty, reason: '/quit says nothing');
    });

    test('end of input exits cleanly', () async {
      final env = _shell([
        scriptedReply('one'),
      ]);
      var asked = 0;
      await runShell(
        shell: env.shell,
        readLine: () async =>
            asked++ == 0 ? 'say something' : null, // then end of input
      );
      expect(env.writer.lines, contains('one'));
      expect(asked, 2, reason: 'the loop stops asking after end of input');
    });

    test('an unknown /word is refused by the shell, no turn', () async {
      final env = _shell([
        scriptedReply('should not run'),
      ]);
      final again = await env.shell.handle('/frobnicate');
      expect(again, isTrue, reason: 'a refused command is not a crash');
      expect(env.writer.lines.last, 'unknown command: /frobnicate');
      expect(env.provider.callCount, 0);
    });
  });

  group('a full turn through the shell', () {
    test('the reply is printed; a tool call produces its line', () async {
      final env = _shell([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'hello.txt', 'content': 'from the model'}),
        ]),
        scriptedReply('wrote hello.txt for you'),
      ]);
      await env.shell.handle('make hello.txt');
      expect(env.provider.callCount, 2,
          reason: 'the tool result went back to the model');
      final lines = env.writer.lines;
      // The reply text comes from the outcome's detail.
      expect(lines, contains('wrote hello.txt for you'));
      // One line for the tool call, naming the tool and what happened.
      final callLine = lines.firstWhere((l) => l.startsWith('· write'));
      expect(callLine, contains('· write'));
      expect(callLine, isNot(contains('✗')),
          reason: 'an allowed write is not an error result');
      // The file was actually written into the workspace.
      expect(
          File('${env.shell.host.config.workingDirectory}/hello.txt')
              .readAsStringSync(),
          'from the model');
      // And the transcript carries the paired tool result.
      final last = env.provider.requests.last;
      final resultMessage =
          last.messages.where((m) => m.role == Role.user).last;
      final block = resultMessage.content.whereType<ToolResultBlock>().single;
      expect(block.toolUseId, 'c1');
      expect(block.isError, isFalse);
    });

    test('a failing command is a line, not a crash', () async {
      final env = _shell([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'exec',
              input: {
                'program': 'ls',
                // A relative name stays inside the session's writable
                // directories, so the gate lets it run — and it exits
                // non-zero because nothing by that name exists.
                'args': ['definitely-not-here'],
              }),
        ]),
        scriptedReply('the command failed as asked'),
      ]);
      await env.shell.handle('run something that fails');
      final callLine =
          env.writer.lines.firstWhere((l) => l.startsWith('· exec'));
      expect(callLine, contains('exit code: 2'),
          reason: 'a failing command is a normal result, not a refusal');
      expect(callLine, isNot(contains('✗')));
      expect(env.writer.lines, contains('the command failed as asked'));
    });

    test('a refused write is an ✗ line with the reason', () async {
      final env = _shell([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': '/etc/tina-must-not-write', 'content': 'x'}),
        ]),
        scriptedReply('understood, it was refused'),
      ]);
      await env.shell.handle('write outside the workspace');
      final callLine =
          env.writer.lines.firstWhere((l) => l.startsWith('· write'));
      expect(callLine, contains('✗'),
          reason: 'the refusal reaches the model as an error result');
      expect(env.writer.lines, contains('understood, it was refused'));
    });

    test('a model error surfaces as the reason and the shell keeps going',
        () async {
      final env = _shell([
        [const StreamError('key rejected', providerCode: 'auth')],
        scriptedReply('recovered'),
      ]);
      await env.shell.handle('first message');
      final reasonLine =
          env.writer.lines.firstWhere((l) => l.startsWith('error:'));
      expect(reasonLine, contains('key rejected'));
      // The loop turns a failed stream into a stopped turn with a
      // detail — assert that contract, not a throw.
      expect(env.provider.callCount, 1);

      await env.shell.handle('second message');
      expect(env.writer.lines, contains('recovered'),
          reason: 'the shell did not die on the error turn');
    });
  });

  group('/mode through the registry', () {
    test('/mode prints the current mode without a turn', () async {
      final env = _shell([]);
      await env.shell.handle('/mode');
      expect(env.writer.lines.last, 'mode: normal');
      expect(env.provider.callCount, 0);
    });

    test('/mode with junk changes nothing and says so through the terminal',
        () async {
      final env = _shell([]);
      await env.shell.handle('/mode sideways');
      expect(env.writer.lines.last, 'no mode named sideways');
      // The mode did not move — the enum stays behind the service; the
      // vocabulary names it.
      expect(
          ModeCommandPlugin.wordFor(
              env.shell.services.get<ModeControl>().mode),
          'normal');
    });

    test('/mode read-only: a write is refused and the refusal reaches '
        'the model as that call\'s tool result', () async {
      final env = _shell([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'blocked.txt', 'content': 'nope'}),
        ]),
        scriptedReply('acknowledged the refusal'),
      ]);
      await env.shell.handle('/mode read-only');
      expect(env.writer.lines, contains('mode: read-only'));
      expect(
          ModeCommandPlugin.wordFor(
              env.shell.services.get<ModeControl>().mode),
          'read-only');

      await env.shell.handle('write a file');
      final last = env.provider.requests.last;
      final resultMessage =
          last.messages.where((m) => m.role == Role.user).last;
      final block = resultMessage.content.whereType<ToolResultBlock>().single;
      expect(block.isError, isTrue);
      expect(block.content, contains('read-only'));

      // The refusal is also what the human sees on the call line.
      final callLine =
          env.writer.lines.firstWhere((l) => l.startsWith('· write'));
      expect(callLine, contains('✗'));
      expect(callLine, contains('read-only'));

      // And nothing was written.
      expect(
          File('${env.shell.host.config.workingDirectory}/blocked.txt')
              .existsSync(),
          isFalse);
    });

    test('/mode normal switches back; the same write then runs', () async {
      final env = _shell([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'later.txt', 'content': 'now it works'}),
        ]),
        scriptedReply('done'),
      ]);
      await env.shell.handle('/mode read-only');
      await env.shell.handle('/mode normal');
      expect(
          ModeCommandPlugin.wordFor(
              env.shell.services.get<ModeControl>().mode),
          'normal');
      expect(env.writer.lines, contains('mode: normal'));

      await env.shell.handle('write it now');
      expect(
          File('${env.shell.host.config.workingDirectory}/later.txt')
              .readAsStringSync(),
          'now it works');
    });

    test('the shell is mode-blind: no mode enum is imported here, the '
        'dispatch goes by name', () {
      final env = _shell([]);
      // The only mode-shaped thing the shell holds is the command
      // plugin the package owns; the mode itself lives behind the
      // ModeControl service.
      expect(env.shell.services.get<ModeControl>(), isNotNull);
      expect(env.shell.commands['mode'], isNotNull);
      expect(env.shell.commands['quit'], isNotNull);
    });
  });

  group('the provider factory seam', () {
    test('an anthropic-wire descriptor builds the anthropic provider', () {
      final provider = providerForDescriptor(
          descriptorByIdFor('anthropic', builtinDescriptors), 'some-model');
      expect(provider.model, 'some-model');
      provider.close();
    });

    test('no descriptor means the anthropic wire', () {
      final provider = providerForDescriptor(null, 'bare-model');
      expect(provider, isA<AnthropicProvider>());
      expect(provider.model, 'bare-model');
      provider.close();
    });
  });
}

// The assembly, driven headless: the scripted provider plays the model, a
// StringBuffer captures everything it says, and no renderer is ever
// initialised. Covers command dispatch through the registry (unknown
// words, /quit, /mode), a full turn through the host, the mode switch
// reaching the model as a refusal on the next write call, and the
// provider factory seam. This was tina_cli's shell_test; the read-line
// loop is gone — what remains is what a front end drives.
//
// Run: dart test
library;

import 'package:tina_tools/tina_tools.dart' show Approval;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_mode/tina_mode.dart' show ModePlugin;
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_self_update/tina_self_update.dart';

/// A captured writer: every line the assembly said, joined.
final class CapturedWriter implements AssemblyWriter {
  final StringBuffer buf = StringBuffer();

  @override
  void writeln([String? line]) => buf.writeln(line ?? '');

  /// Everything written, as one string.
  String get text => buf.toString();

  /// The lines written, without their trailing newlines.
  List<String> get lines => const LineSplitter().convert(text.trimRight());
}

/// An assembly over a temp workspace whose provider plays [script]. No
/// terminal in the slot: the headless drive is the point.
({TuiAssembly assembly, CapturedWriter writer, ScriptedProvider provider})
    _assembly(List<List<StreamEvent>> script) {
  final ws = Directory.systemTemp.createTempSync('tina_tui_ws_');
  addTearDown(() => ws.deleteSync(recursive: true));
  final writer = CapturedWriter();
  final provider = ScriptedProvider(script);
  final assembly = TuiAssembly.start(
    writer: writer,
    providerFactory: (_) => provider,
    options: AssemblyOptions(
      configPath: '/nonexistent/tina/config',
      workingDirectory: ws.path,
    ),
  );
  return (assembly: assembly, writer: writer, provider: provider);
}

void main() {
  test('automatic approval follows model switches', () async {
    final ws = Directory.systemTemp.createTempSync('tina_judge_model_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final models = <String>[];
    final app = TuiAssembly.start(
      providerFactory: (model) {
        models.add(model);
        return _StructuredJudge(model);
      },
      options: AssemblyOptions(
          configPath: '/nonexistent/tina/config', workingDirectory: ws.path),
    );
    addTearDown(app.close);
    await app.handleCommand('/model switched-model');
    models.clear();
    final judgment =
        await app.tools.modePolicy.classifier!.classify({'command': 'ls'});
    expect(judgment.allow, true);
    expect(models, ['switched-model']);
    expect(judgment.diagnostics['model'], 'switched-model');
  });

  test('restart handoff resumes saved activity and exits the requesting panel',
      () async {
    final ws = Directory.systemTemp.createTempSync('tina_restart_');
    addTearDown(() => ws.deleteSync(recursive: true));
    String? root;
    String? id;
    final app = TuiAssembly.start(
        providerFactory: (_) => ScriptedProvider([scriptedReply('hello')]),
        options: AssemblyOptions(
          configPath: '/nonexistent/tina/config',
          workingDirectory: ws.path,
          onRestart: (bundle, session) {
            root = bundle;
            id = session;
          },
        ));
    addTearDown(app.close);
    app.host.plugins.whereType<UpdatePlugin>().single.restart!('/new/bundle');
    expect(root, '/new/bundle');
    expect(id, isNull, reason: 'empty sessions must not be resumed');
    expect(app.quitRequested, isTrue);
    final panel = app.newSession(null);
    addTearDown(panel.close);
    await panel.host.send('hello');
    panel.host.plugins
        .whereType<UpdatePlugin>()
        .single
        .restart!('/updated/bundle');
    expect(root, '/updated/bundle');
    expect(id, panel.host.session.id);
    expect(panel.quitRequested, isTrue);
  });

  group('headless by construction', () {
    test('a session assembles without a physical terminal and runs a full turn',
        () async {
      final env = _assembly([
        scriptedReply('the model answered'),
      ]);
      expect(env.assembly.terminal, isA<TuiTerminal>(),
          reason: 'output is buffered without physical terminal I/O');
      await env.assembly.host.send('say something');
      expect(env.provider.callCount, 1);
      expect(env.assembly.host.session.lastReply, 'the model answered');
      // The log is the full turn — input, request, response, stop.
      expect(env.assembly.host.session.turns, hasLength(1));
      env.assembly.close();
    });

    test('the assembly prints nothing on its own; the config note is a value',
        () async {
      final env = _assembly([]);
      expect(env.writer.text, isEmpty,
          reason: 'a full-screen front end owns its banner');
      expect(env.assembly.configNote, isNull,
          reason: 'the config file was absent');
      env.assembly.close();
    });
  });

  group('command dispatch through the registry', () {
    test('an unknown /word is refused by the assembly, no turn', () async {
      final env = _assembly([
        scriptedReply('should not run'),
      ]);
      final again = await env.assembly.handleCommand('/frobnicate');
      expect(again, isTrue, reason: 'a refused command is not a crash');
      expect(env.writer.lines.last, 'unknown command: /frobnicate');
      expect(env.provider.callCount, 0);
      env.assembly.close();
    });

    test('/quit flags the loop to stop', () async {
      final env = _assembly([]);
      final again = await env.assembly.handleCommand('/quit');
      expect(again, isFalse);
      expect(env.assembly.quitRequested, isTrue);
      expect(env.writer.text, isEmpty, reason: '/quit says nothing');
      env.assembly.close();
    });

    test('a non-command line is nothing to handleCommand', () async {
      final env = _assembly([
        scriptedReply('should not run'),
      ]);
      expect(await env.assembly.handleCommand('plain words'), isTrue);
      expect(env.writer.text, isEmpty);
      expect(env.provider.callCount, 0,
          reason: 'turns are the front end\u2019s call, via host.send');
      env.assembly.close();
    });

    test('/mode prints the current mode without a turn', () async {
      final env = _assembly([]);
      await env.assembly.handleCommand('/mode');
      // Headless: there is no terminal in the slot, so the plugin's
      // tell is dropped — the mode value is the fact a front end would
      // render.
      expect(env.writer.text, isEmpty);
      expect(env.provider.callCount, 0);
      env.assembly.close();
    });

    test('/mode with junk changes nothing and says so', () async {
      final env = _assembly([]);
      await env.assembly.handleCommand('/mode sideways');
      // The mode did not move — the enum stays behind the service; the
      // vocabulary names it.
      expect(ModePlugin.wordFor(env.assembly.tools.mode), 'ask');
      env.assembly.close();
    });

    test(
        'the assembly is mode-blind: no mode enum is imported here, the '
        'dispatch goes by name', () {
      final env = _assembly([]);
      expect(env.assembly.tools, isNotNull);
      expect(env.assembly.commands['mode'], isNotNull);
      expect(env.assembly.commands['quit'], isNotNull);
      env.assembly.close();
    });
  });

  group('a full turn through the host', () {
    test('a tool call runs, pairs its result, and writes the file', () async {
      final env = _assembly([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'hello.txt', 'content': 'from the model'}),
        ]),
        scriptedReply('wrote hello.txt for you'),
      ]);
      await env.assembly.handleCommand('/mode allow-edits');
      final outcome = await env.assembly.host.send('make hello.txt');
      expect(env.provider.callCount, 2,
          reason: 'the tool result went back to the model');
      // The transcript carries the paired tool result.
      final resultMessage =
          outcome.messages.where((m) => m.role == Role.user).last;
      final block = resultMessage.content.whereType<ToolResultBlock>().single;
      expect(block.toolUseId, 'c1');
      expect(block.isError, isFalse);
      // The file was actually written into the workspace.
      expect(
          File('${env.assembly.host.config.workingDirectory}/hello.txt')
              .readAsStringSync(),
          'from the model');
      env.assembly.close();
    });

    test('a failing command is a normal result, not a refusal', () async {
      final env = _assembly([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'c1', name: 'exec', input: {
            'program': 'ls',
            // A relative name stays inside the session's writable
            // directories, so the gate lets it run — and it exits
            // non-zero because nothing by that name exists.
            'args': ['definitely-not-here'],
          }),
        ]),
        scriptedReply('the command failed as asked'),
      ]);
      env.assembly.tools.processRunner.commandApprover =
          (_, __) async => Approval.yes;
      final outcome = await env.assembly.host.send('run something that fails');
      final resultMessage =
          outcome.messages.where((m) => m.role == Role.user).last;
      final block = resultMessage.content.whereType<ToolResultBlock>().single;
      expect(block.isError, isTrue,
          reason:
              'a nonzero exit is a failed execution, reported with its output');
      // BSD ls returns 1; GNU ls returns 2 for the same missing file.
      expect(block.content, matches(r'exit code: [1-9][0-9]*'));
      expect(block.content, contains('definitely-not-here'));
      env.assembly.close();
    });

    test(
        'a write outside the workspace is refused — unattached channel, fail '
        'closed', () async {
      final env = _assembly([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': '/etc/tina-must-not-write', 'content': 'x'}),
        ]),
        scriptedReply('understood, it was refused'),
      ]);
      final outcome = await env.assembly.host.send('write outside');
      final resultMessage =
          outcome.messages.where((m) => m.role == Role.user).last;
      final block = resultMessage.content.whereType<ToolResultBlock>().single;
      expect(block.isError, isTrue,
          reason: 'the refusal reaches the model as an error result');
      expect(block.content, contains('approval denied or cancelled'));
      expect(File('/etc/tina-must-not-write').existsSync(), isFalse);
      env.assembly.close();
    });

    test(
        'a model error surfaces as a stopped turn and the session keeps '
        'going', () async {
      final env = _assembly([
        [const StreamError('key rejected', providerCode: 'auth')],
        scriptedReply('recovered'),
      ]);
      await env.assembly.host.send('first message');
      expect(env.provider.callCount, 1);

      await env.assembly.host.send('second message');
      expect(env.assembly.host.session.lastReply, 'recovered',
          reason: 'the session did not die on the error turn');
    });
  });

  group('/mode read-only: the boundary refuses, then relents', () {
    test(
        'a write is refused and the refusal reaches the model as that '
        'call\u2019s tool result', () async {
      final env = _assembly([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'blocked.txt', 'content': 'nope'}),
        ]),
        scriptedReply('acknowledged the refusal'),
      ]);
      await env.assembly.handleCommand('/mode read-only');
      expect(ModePlugin.wordFor(env.assembly.tools.mode), 'read-only');

      await env.assembly.host.send('write a file');
      final last = env.provider.requests.last;
      final resultMessage =
          last.messages.where((m) => m.role == Role.user).last;
      final block = resultMessage.content.whereType<ToolResultBlock>().single;
      expect(block.isError, isTrue);
      expect(block.content, contains('read-only'));
      expect(
          File('${env.assembly.host.config.workingDirectory}/blocked.txt')
              .existsSync(),
          isFalse);
      env.assembly.close();
    });

    test('/mode allow-edits switches back; the same write then runs', () async {
      final env = _assembly([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'later.txt', 'content': 'now it works'}),
        ]),
        scriptedReply('done'),
      ]);
      await env.assembly.handleCommand('/mode read-only');
      await env.assembly.handleCommand('/mode allow-edits');
      expect(ModePlugin.wordFor(env.assembly.tools.mode), 'allow-edits');

      await env.assembly.host.send('write it now');
      expect(
          File('${env.assembly.host.config.workingDirectory}/later.txt')
              .readAsStringSync(),
          'now it works');
      env.assembly.close();
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

    test('an explicit factory wins over the config-driven one', () async {
      final env = _assembly([scriptedReply('scripted says hi')]);
      expect(env.provider.model, 'scripted');
      await env.assembly.host.send('x');
      expect(env.provider.callCount, 1);
      env.assembly.close();
    });
  });
}

class _StructuredJudge extends LlmProvider implements StructuredOutputProvider {
  _StructuredJudge(super.model);
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      Stream.fromIterable(scriptedReply('hello'));
  @override
  Stream<StreamEvent> sendStructured(
          {required String system,
          required List<Message> messages,
          required JsonOutputSchema output}) =>
      Stream.fromIterable(scriptedReply('{"decision":"ALLOW"}'));
}

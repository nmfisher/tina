// The required host behaviors, headless: no terminal, no network, the
// scripted provider from tina_engine_2 plays the model. The permission
// mode lives in the ToolsPlugin — the host is mode-blind.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persona/tina_persona.dart';
import 'package:tina_tools/tina_tools.dart'
    show ModeControl, PermissionMode, ToolsPlugin, Approval;

/// A config over a temp workspace: one ScriptedProvider per call — the
/// factory shape the daemon-readiness rule requires — counting builds so
/// tests can assert per-host construction. The tools plugin carries the
/// mode; the config does not know the concept.
HostConfig _config(
  Directory ws,
  Directory tina,
  List<List<StreamEvent>> script, {
  PermissionMode mode = PermissionMode.allowEdits,
  required void Function() onBuild,
}) =>
    HostConfig(
      providerFactory: (model) {
        onBuild();
        expect(model, 'scripted');
        return ScriptedProvider(script);
      },
      workingDirectory: ws.path,
      plugins: [ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina, mode: mode)],
    );

class _ClosingProvider extends LlmProvider {
  _ClosingProvider() : super('test');
  int closes = 0;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) =>
      const Stream.empty();

  @override
  void close() => closes++;
}

void main() {
  late Directory ws;
  late Directory tina;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_host_ws_');
    tina = await Directory.systemTemp.createTemp('tina_host_tina_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
    tina.deleteSync(recursive: true);
  });

  test('process tools use the workspace and obey subsequent mode changes',
      () async {
    final plugin =
        ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina, osSandbox: false)
          ..processRunner.commandApprover = (_, __) async => Approval.yes;
    final exec =
        plugin.toolList.singleWhere((tool) => tool.schema.name == 'exec');
    final first = await exec.execute({'program': '/bin/pwd'});
    expect(first.isError, false);
    expect(first.content, contains(ws.resolveSymbolicLinksSync()));
    plugin.mode = PermissionMode.readOnly;
    final second = await exec.execute({'program': '/bin/pwd'});
    expect(second.isError, true);
    expect(second.content, contains('read-only mode'));
  });

  group('a turn runs end to end', () {
    test('closing a host releases only its own provider, once', () {
      final providers = <_ClosingProvider>[];
      final config = HostConfig(
        providerFactory: (_) {
          final provider = _ClosingProvider();
          providers.add(provider);
          return provider;
        },
        workingDirectory: ws.path,
      );
      final first = Host.start(config);
      final second = Host.start(config);
      first.close();
      first.close();
      expect(providers.map((p) => p.closes), [1, 0]);
      expect(() => first.send('after close'), throwsStateError);
      second.close();
      expect(providers.map((p) => p.closes), [1, 1]);
    });

    test('the assistant reply comes back through the host', () async {
      var builds = 0;
      final host = Host.start(_config(
          ws,
          tina,
          [
            scriptedReply('hello from the model'),
          ],
          onBuild: () => builds++));
      expect(builds, 1, reason: 'start builds exactly one provider');

      final outcome = await host.send('say hello');

      expect(outcome.stopReason, StopReason.complete);
      expect(host.session.lastReply, 'hello from the model');
      // The turn is recorded on the session.
      expect(host.session.turns, hasLength(1));
    });
  });

  group('tools on the loop', () {
    test('schemas are advertised; an advertised tool actually runs', () async {
      final host = Host.start(_config(
          ws,
          tina,
          [
            scriptedReply('', calls: [
              ToolUseBlock(
                  id: 'c1',
                  name: 'write',
                  input: {'filePath': 'made.txt', 'content': 'by the model'}),
            ]),
            scriptedReply('wrote it'),
          ],
          onBuild: () {}));

      final outcome = await host.send('make a file');

      // The provider was offered exactly the six file tools plus the two
      // process tools (bash, exec), which run through the OS sandbox and
      // the permission gate.
      final offered = host.session.turns.last.modelRequests.first.tools
          .map((t) => t.name)
          .toList();
      expect(
          offered,
          containsAll([
            'ls',
            'read',
            'write',
            'edit',
            'glob',
            'stat',
          ]));
      expect(offered, hasLength(8));
      // The advertised tool's executor ran: the file landed in the
      // session's working directory.
      expect(File('${ws.path}/made.txt').readAsStringSync(), 'by the model');
      expect(outcome.stopReason, StopReason.complete);
    });
  });

  group('the sandbox is the boundary', () {
    test('a write inside the project runs in allow-edits mode', () async {
      final host = Host.start(_config(
          ws,
          tina,
          [
            scriptedReply('', calls: [
              ToolUseBlock(
                  id: 'c1',
                  name: 'write',
                  input: {'filePath': 'inside.txt', 'content': 'fine'}),
            ]),
            scriptedReply('done'),
          ],
          onBuild: () {}));

      final outcome = await host.send('write inside');
      final result = outcome.messages
          .whereType<Message>()
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .single;

      expect(result.isError, isFalse);
      expect(File('${ws.path}/inside.txt').existsSync(), isTrue);
    });

    test(
        'a write in a read-only session is refused, and the refusal is '
        'the tool_result the model reads — the turn continues', () async {
      final host = Host.start(_config(
          ws,
          tina,
          [
            scriptedReply('', calls: [
              ToolUseBlock(
                  id: 'c1',
                  name: 'write',
                  input: {'filePath': 'blocked.txt', 'content': 'x'}),
            ]),
            scriptedReply('understood, staying read-only'),
          ],
          mode: PermissionMode.readOnly,
          onBuild: () {}));
      // The mode was set where it lives: on the plugin that owns the
      // boundary. Nothing on the host was told.
      final tools = host.config.plugins.whereType<ToolsPlugin>().single;
      expect(tools.mode, PermissionMode.readOnly);

      final outcome = await host.send('try to write');

      expect(outcome.stopReason, StopReason.complete);
      final result = outcome.messages
          .whereType<Message>()
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .single;
      expect(result.isError, isTrue);
      expect(result.content, contains('read-only mode'));
      // And nothing was written.
      expect(File('${ws.path}/blocked.txt').existsSync(), isFalse);
    });
  });

  group('switching mode through the plugin', () {
    test(
        'changes what the file system does on the next call — the host '
        'is not involved', () async {
      final host = Host.start(_config(
          ws,
          tina,
          [
            scriptedReply('', calls: [
              ToolUseBlock(
                  id: 'c1',
                  name: 'write',
                  input: {'filePath': 'first.txt', 'content': '1'}),
            ]),
            scriptedReply('wrote'),
            // After the switch, the model tries the same write.
            scriptedReply('', calls: [
              ToolUseBlock(
                  id: 'c2',
                  name: 'write',
                  input: {'filePath': 'second.txt', 'content': '2'}),
            ]),
            scriptedReply('refused'),
          ],
          onBuild: () {}));
      final tools = host.config.plugins.whereType<ToolsPlugin>().single;

      await host.send('write the first');
      expect(File('${ws.path}/first.txt').existsSync(), isTrue);

      // The mode's only handle: the plugin that owns the boundary.
      tools.mode = PermissionMode.readOnly;
      expect(tools.mode, PermissionMode.readOnly);

      await host.send('write the second');
      final result = host.session.turns.last.messages
          .whereType<Message>()
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .single;
      expect(result.isError, isTrue,
          reason: 'the switch binds the very next call');
      expect(result.content, contains('read-only mode'));
      expect(File('${ws.path}/second.txt').existsSync(), isFalse);
      // Same session, same loop, same tools — only the mode moved, and
      // only the plugin moved it.
      expect(host.session.turns, hasLength(2));
    });
  });

  group('the system prompt section', () {
    test('the tools plugin contributes it, and the provider receives it',
        () async {
      // The loop keeps its provider private, so the factory hands the
      // instance back here to inspect what it received.
      ScriptedProvider? built;
      final host = Host.start(HostConfig(
        providerFactory: (model) => built = ScriptedProvider([
          scriptedReply('noted'),
        ]),
        workingDirectory: ws.path,
        plugins: [
          const PersonaPlugin(),
          ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina),
        ],
      ));

      await host.send('hello');

      // The loop hands the provider the system prompt; the persona plugin
      // leads it and the tools plugin's section is inside it, under it.
      final request = built!.requests.single;
      expect(request.systemPrompt,
          startsWith('You are tina, a terminal coding agent.'));
      expect(request.systemPrompt, contains('Working directory: ${ws.path}'));
      expect(request.systemPrompt, contains('Mode: ask'));
    });
  });

  group('two hosts from one config', () {
    test('do not share a provider instance', () {
      final builds = <LlmProvider>[];
      final counting = HostConfig(
        providerFactory: (model) {
          final p = ScriptedProvider([]);
          builds.add(p);
          return p;
        },
        workingDirectory: ws.path,
        plugins: [ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina)],
      );

      final a = Host.start(counting);
      final b = Host.start(counting);

      expect(builds, hasLength(2), reason: 'the factory ran once per host');
      expect(identical(builds[0], builds[1]), isFalse,
          reason: 'two hosts never share a provider');
      expect(a.session.id, isNot(b.session.id));
    });
  });

  group('the mode control is explicit', () {
    test('the tools plugin exposes the mounted mode control', () {
      final config = HostConfig(
        providerFactory: (model) => ScriptedProvider([]),
        workingDirectory: ws.path,
        plugins: [
          ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina),
        ],
      );

      final host = Host.start(config);
      addTearDown(host.close);

      final control =
          (host.config.plugins.whereType<ToolsPlugin>().single as ModeControl);
      expect(control.mode, PermissionMode.ask);
    });

    test('the tools plugin works without a terminal', () {
      final config = HostConfig(
        providerFactory: (model) => ScriptedProvider([]),
        workingDirectory: ws.path,
        plugins: [ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina)],
      );

      final host = Host.start(config);

      expect(host.session.loop, isNotNull);
    });

    test(
        'the service reads the live mode: a later plugin flip is visible at use',
        () {
      final config = HostConfig(
        providerFactory: (model) => ScriptedProvider([]),
        workingDirectory: ws.path,
        plugins: [
          ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina),
        ],
      );
      final host = Host.start(config);

      // The plugin is the authority; the service is a window over it.
      host.config.plugins.whereType<ToolsPlugin>().single.mode =
          PermissionMode.readOnly;

      expect(
          (host.config.plugins.whereType<ToolsPlugin>().single as ModeControl)
              .mode,
          PermissionMode.readOnly);
    });

    test('writing through the service changes what the sandbox does next',
        () async {
      final config = HostConfig(
        providerFactory: (model) => ScriptedProvider([
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'write',
                input: {'filePath': 'blocked.txt', 'content': 'x'}),
          ]),
          scriptedReply('understood, staying read-only'),
        ]),
        workingDirectory: ws.path,
        plugins: [
          ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina),
        ],
      );
      final host = Host.start(config);

      (host.config.plugins.whereType<ToolsPlugin>().single as ModeControl)
          .mode = PermissionMode.readOnly;

      await host.send('try to write');
      final outcome = host.session.turns.single;
      final toolResult = outcome.messages
          .whereType<Message>()
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .single;
      expect(toolResult.isError, isTrue);
      expect(toolResult.content, contains('read-only mode'));
    });
  });
}

import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';

void main() {
  late PluginScope scope;
  late CommandRegistry commands;
  late FakeHostInterface host;
  setUp(() {
    scope = PluginScope('commands');
    commands = CommandRegistry(scope);
    host = FakeHostInterface();
  });
  tearDown(() async {
    await scope.dispose();
    await host.dispose();
  });
  Registration register(String id, Command command) =>
      scope.registerContribution(pluginId: id, id: id, contribution: command);
  Future<CmdResult> dispatch(String line, {Future<void>? cancel}) => commands
      .dispatch(line, host: host, conversationId: 'test', cancelSignal: cancel);

  test(
    'live contributions share dispatch, aliases, help and completion metadata',
    () async {
      final registration = register(
        'greet',
        Command(
          names: ['/hello', '/hi'],
          argsHint: '<name>',
          summary: 'greet someone',
          handler: (call) async {
            expect(call.word, '/hi');
            expect(call.conversationId, 'test');
            call.write('hello ${call.arguments}\n');
            return const CmdHandled();
          },
        ),
      );
      expect(commands.allNames, ['/hello', '/hi']);
      expect(commands.renderHelp(), contains('/hello <name>'));
      expect(
        identical(commands.lookup('/hello'), commands.lookup('/hi')),
        isTrue,
      );
      expect(await dispatch('/hi Ada'), isA<CmdHandled>());
      expect(host.messages.last, 'hello Ada\n');
      await registration.dispose();
      expect(commands.allNames, isEmpty);
      expect(commands.renderHelp(), isNot(contains('/hello')));
      expect((await dispatch('/hi Ada') as CmdHandled).failed, isTrue);
    },
  );

  test('collisions across plugin scopes and aliases are rejected', () async {
    register(
      'base',
      Command(
        names: ['/one', '/alias'],
        summary: 'base',
        handler: (_) async => const CmdHandled(),
      ),
    );
    final child = PluginScope('child', parent: scope);
    addTearDown(child.dispose);
    child.registerContribution(
      pluginId: 'extension',
      id: 'different-id',
      contribution: Command(
        names: ['/alias'],
        summary: 'collision',
        handler: (_) async => const CmdHandled(),
      ),
    );
    expect(() => CommandRegistry(child), throwsStateError);
    register(
      'another',
      Command(
        names: ['/one'],
        summary: 'collision',
        handler: (_) async => const CmdHandled(),
      ),
    );
    expect(() => commands.allNames, throwsStateError);
    expect((await dispatch('/one') as CmdHandled).failed, isTrue);
    expect(host.messages.join(), contains('Duplicate command'));
  });

  test('feature selection belongs to each command view', () {
    register(
      'optional',
      Command(
        names: ['/optional'],
        summary: 'optional',
        feature: 'feature',
        handler: (_) async => const CmdHandled(),
      ),
    );
    final hidden = CommandRegistry(scope, hiddenFeatures: {'feature'});
    expect(hidden.allNames, isEmpty);
    expect(hidden.lookup('/optional'), isNull);
    expect(hidden.renderHelp(), isNot(contains('/optional')));
    expect(commands.allNames, ['/optional']);
  });

  test(
    'cancellation releases a stalled command and suppresses late output and CmdRun',
    () async {
      final start = Completer<CommandCall>();
      final release = Completer<void>();
      register(
        'slow',
        Command(
          names: ['/slow'],
          summary: 'wait',
          handler: (call) async {
            start.complete(call);
            await release.future;
            call.write('too late');
            return const CmdRun('must not start');
          },
        ),
      );
      final stop = Completer<void>();
      final pending = dispatch('/slow', cancel: stop.future);
      final call = await start.future;
      stop.complete();
      expect(
        await pending.timeout(const Duration(seconds: 1)),
        isA<CmdHandled>(),
      );
      expect(call.isCancelled, isTrue);
      final before = host.messages.toList();
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(host.messages, before);
    },
  );

  test(
    'hooks run before alias handlers; revoked handlers cannot dispatch',
    () async {
      final fired = <String>[];
      final registration = register(
        'alias',
        Command(
          names: ['/one', '/alias'],
          summary: 'one',
          handler: (_) async {
            fired.add('handler');
            return const CmdHandled();
          },
        ),
      );
      await commands.dispatch(
        '/alias',
        host: host,
        conversationId: 'test',
        hooks: {
          '/alias': () {
            fired.add('hook');
          },
        },
      );
      expect(fired, ['hook', 'handler']);
      final result = await commands.dispatch(
        '/one',
        host: host,
        conversationId: 'test',
        hooks: {'/one': registration.dispose},
      );
      expect((result as CmdHandled).failed, isTrue);
      expect(fired, ['hook', 'handler']);
    },
  );

  test(
    'a command can submit a prompt and ordinary text bypasses dispatch',
    () async {
      register(
        'ask',
        Command(
          names: ['/ask'],
          summary: 'ask',
          handler: (call) async => CmdRun(call.arguments),
        ),
      );
      expect((await dispatch('/ask hello') as CmdRun).prompt, 'hello');
      host.messages.clear();
      expect(await dispatch('ordinary input'), isA<CmdNotCommand>());
      expect(host.messages, isEmpty);
    },
  );
}

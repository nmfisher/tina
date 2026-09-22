import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/session_commands/headless_commands.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/memory_session_store.dart';

void main() {
  test('headless built-ins and app commands share dispatch and help', () async {
    final root = await Directory.systemTemp.createTemp('headless-commands-');
    addTearDown(() => root.delete(recursive: true));
    late Registration registration;
    final app = await buildAppComposition(
      config: RuntimeConfig(provider: 'unused', model: 'unused'),
      registry: ProviderRegistry(env: const {}),
      store: MemorySessionStore(),
      workspaceRoot: root.path,
      plugins: [
        PluginDescriptor(
          id: 'hello',
          factory: FnPluginFactory((context) {
            registration = context.register(
              Command(
                names: ['/hello', '/hi'],
                summary: 'say hello',
                handler: (call) async => CmdRun('hello ${call.arguments}'),
              ),
              id: 'hello.command',
            );
            return Object();
          }),
        ),
      ],
    );
    addTearDown(app.dispose);
    final runtime = headlessCommands(app);
    addTearDown(runtime.dispose);
    final commands = CommandRegistry(runtime.scope);
    final host = FakeHostInterface();
    addTearDown(host.dispose);
    Future<CmdResult> run(String line) => commands.dispatch(
      line,
      host: host,
      conversationId: app.initialConversationId,
    );

    expect(await run('/help'), isA<CmdHandled>());
    expect(host.messages.last, contains('/hello'));
    expect(host.messages.last, contains('/index'));
    expect(commands.lookup('/settings'), isNull);
    expect((await run('/hi world') as CmdRun).prompt, 'hello world');
    expect((await run('/index invalid') as CmdHandled).failed, isTrue);
    expect(host.messages.last, contains('/index'));
    expect((await run('/index jev view') as CmdHandled).failed, isFalse);
    expect(host.messages.last, contains('No saved index'));
    expect(
      await Directory('${root.path}/.tina/classifications').exists(),
      isFalse,
    );
    await registration.dispose();
    expect(commands.allNames, isNot(contains('/hello')));
    expect((await run('/hello') as CmdHandled).failed, isTrue);
    await runtime.dispose();
    expect(app.pluginScope!.isAdmitting, isTrue);
  });
}

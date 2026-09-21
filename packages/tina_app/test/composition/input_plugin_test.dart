import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/memory_session_store.dart';

class Router implements InputRouter {
  @override
  Future<InputRoute?> route(InputContext input) async => InputRoute('echo');
}

class Echo implements InputHandler {
  @override
  Future<String> handle(InputContext input, InputRoute route) async =>
      input.text;
}

void main() {
  test(
    'app extensions use the existing registry, services and plugin lifetime',
    () async {
      final root = await Directory.systemTemp.createTemp('input-plugin-');
      addTearDown(() => root.delete(recursive: true));
      var disposed = false;
      late Registration router;
      late SpendLedger ledger;
      final app = await buildAppComposition(
        config: RuntimeConfig(provider: 'unused', model: 'unused'),
        registry: ProviderRegistry(env: const {}),
        store: MemorySessionStore(),
        projectRoot: root.path,
        plugins: [
          PluginDescriptor(
            id: 'echo-plugin',
            requires: {spendLedgerServiceKey},
            factory: FnPluginFactory((context) {
              ledger = context.require(spendLedgerServiceKey);
              router = context.register(Router(), id: 'echo-router');
              context.register(Echo(), id: 'echo');
              context.own(() {
                disposed = true;
              });
              return Object();
            }),
          ),
        ],
      );
      addTearDown(app.dispose);
      expect(identical(ledger, app.spendLedger), isTrue);
      final host = FakeHostInterface();
      addTearDown(host.dispose);
      final history = <Message>[];
      Future<InputOutcome> run() => app.inputRoutes!.run(
        text: 'echo this',
        conversationId: 'test',
        history: history,
        cancelSignal: Completer<void>().future,
        host: host,
      );
      expect(await run(), InputOutcome.handled);
      expect(host.sink.texts.join(), 'echo this');
      await router.dispose();
      expect(await run(), InputOutcome.pass);
      expect(history, hasLength(2));
      await app.dispose();
      expect(disposed, isTrue);
      expect(await run(), InputOutcome.failed);
      expect(host.messages.join(), contains('scope is closed'));
    },
  );
}

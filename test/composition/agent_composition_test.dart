import 'package:tina_engine/tina_engine.dart';
import 'package:tina/composition/agent_composition.dart';
import 'package:tina/config.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Pins the composition wiring: `createScheduler` over the default pipeline,
/// and `buildAgent`'s interactive/headless split — the structural guarantee
/// that interactive main can't edit files (delegate + channels only) while
/// headless `--prompt` main runs as a direct worker with the full base set.
void main() {
  Config testConfig() => Config.parse(const ['--backend', 'ansi']);

  group('buildAgent main tool set', () {
    test('interactive main gets delegate + channels, NO file tools', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final agent = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config, // withSubAgents defaults true
      );
      for (final t in ['delegate', 'send', 'receive', 'close']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      for (final t in ['read', 'write', 'edit', 'bash', 'search', 'grep', 'glob']) {
        expect(agent.tools[t], isNull,
            reason: '$t must be absent — interactive main cannot edit files');
      }
    });

    test('headless main gets the full base set, no delegate/channels', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final agent = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        withSubAgents: false,
      );
      for (final t in ['read', 'write', 'edit', 'bash', 'search', 'grep', 'glob']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      expect(agent.tools['delegate'], isNull);
      expect(agent.tools['send'], isNull);
    });
  });
}

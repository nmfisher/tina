import 'package:test/test.dart';
import 'package:tina/composition/provider_resolution.dart';
import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';

/// A [ProviderBuilder] that records every [ProviderInstance] it received and
/// returns a throwaway provider. Lets us assert exactly what [buildResolved]
/// handed to the registry without standing up a real provider.
ProviderBuilder _recording(List<ProviderInstance> into) => (c) {
      into.add(c);
      return _NoopProvider(c.model);
    };

ProviderDescriptor _desc(
  String id, {
  String baseUrl = 'https://example.test',
  List<AuthSource> auth = const [
    AuthSource('TEST_KEY', AuthScheme.bearerToken),
  ],
  Map<String, ModelInfo> models = const {},
  required ProviderBuilder builder,
}) =>
    ProviderDescriptor(
      id: id,
      name: id,
      authSources: auth,
      defaultBaseUrl: baseUrl,
      builder: builder,
      models: models,
    );

class _NoopProvider extends LlmProvider {
  _NoopProvider(super.model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {}
}

/// A [Config] whose startup provider is [id], parsed the way main() parses it
/// (a full `id/model` ref on the command line) with the provider registered so
/// the descriptor lookup succeeds. [Config.apiKey] resolves from [env] via the
/// descriptor's auth source.
Config _config(
  String id, {
  Map<String, String> env = const {'TEST_KEY': 'startup-key'},
}) {
  final parseRegistry =
      ProviderRegistry(env: env)..register(_desc(id, builder: _recording([])));
  return Config.parse(
    ['--model', '$id/m1', '--max-tokens', '4096'],
    env: env,
    registry: parseRegistry,
  );
}

/// A registry holding recording builders for every provider [buildResolved]
/// may name in these tests: the startup provider `prov`, a second provider
/// `other`, and a provider named like a bare model id (`bare-model`) so a
/// bare-ref build has something to resolve against.
({ProviderRegistry registry, List<ProviderInstance> prov, List<ProviderInstance> other, List<ProviderInstance> bare})
    _recordingRegistry() {
  final prov = <ProviderInstance>[];
  final other = <ProviderInstance>[];
  final bare = <ProviderInstance>[];
  final registry = ProviderRegistry(env: const {'TEST_KEY': 'env-key'})
    ..register(_desc('prov', builder: _recording(prov)))
    ..register(
      _desc(
        'other',
        baseUrl: 'https://other-default.test',
        builder: _recording(other),
      ),
    )
    ..register(_desc('bare-model', builder: _recording(bare), models: const {
      'm1': ModelInfo(
        id: 'm1',
        name: 'm1',
        contextWindow: 8192,
        maxOutput: 4096,
      ),
    }));
  return (
    registry: registry,
    prov: prov,
    other: other,
    bare: bare,
  );
}

void main() {
  group('refProviderForBuild', () {
    test('a "provider/model" ref names the provider before the first slash', () {
      expect(refProviderForBuild('openai/gpt-5'), 'openai');
      expect(refProviderForBuild('a/b/c'), 'a');
    });

    test('a bare model ref has no provider', () {
      expect(refProviderForBuild('glm-5.2'), isNull);
    });
  });

  group('appliesToStartupProvider', () {
    test('an explicit "provider/model" match may inherit', () {
      expect(appliesToStartupProvider('prov/m1', 'prov'), isTrue);
    });

    test('a different provider may not inherit', () {
      expect(appliesToStartupProvider('other/m1', 'prov'), isFalse);
    });

    test('a bare model ref may not inherit (historical restore semantics)',
        () {
      expect(appliesToStartupProvider('m1', 'prov'), isFalse);
    });
  });

  group('buildResolved', () {
    test('the startup key and base URL reach a same-provider build', () {
      final rr = _recordingRegistry();
      final config = _config('prov');
      expect(config.apiKey, 'startup-key');
      expect(config.baseUrl, 'https://example.test');

      buildResolved(
        rr.registry,
        config,
        'prov/m2',
        apiKeyOverride: 'override-key',
        baseUrlOverride: 'https://override.test',
      );

      expect(rr.prov, hasLength(1));
      expect(rr.prov.single.apiKey, 'override-key');
      expect(rr.prov.single.baseUrl, 'https://override.test');
      expect(rr.prov.single.model, 'm2');
      expect(rr.prov.single.authScheme, AuthScheme.bearerToken);
    });

    test('a different provider builds from its own env and default URL', () {
      final rr = _recordingRegistry();
      final config = _config('prov');

      buildResolved(
        rr.registry,
        config,
        'other/m2',
        apiKeyOverride: 'override-key',
        baseUrlOverride: 'https://override.test',
      );

      expect(rr.other, hasLength(1));
      expect(rr.other.single.apiKey, 'env-key');
      expect(rr.other.single.baseUrl, 'https://other-default.test');
    });

    test('a bare model ref builds with nothing inherited', () {
      final rr = _recordingRegistry();
      final config = _config('prov');

      buildResolved(
        rr.registry,
        config,
        'm1',
        apiKeyOverride: 'override-key',
        baseUrlOverride: 'https://override.test',
      );

      expect(rr.bare, hasLength(1));
      expect(rr.bare.single.apiKey, 'env-key');
      expect(rr.bare.single.baseUrl, 'https://example.test');
      expect(rr.bare.single.model, 'm1');
    });

    test('the config tuning knobs are forwarded', () {
      final rr = _recordingRegistry();
      final config = _config('prov');
      expect(config.maxTokens, 4096);

      buildResolved(rr.registry, config, 'prov/m2');

      expect(rr.prov.single.maxTokens, config.maxTokens);
      expect(rr.prov.single.streamIdleTimeout, config.streamIdleTimeout);
      expect(rr.prov.single.requestTimeout, config.requestTimeout);
    });
  });

  group('apiKeyForPickedRef', () {
    test('the providers block for the ref provider wins', () {
      final cfg = UserConfig(
        providers: {
          'prov': ProviderConfig(apiKey: 'file-key'),
          'other': ProviderConfig(apiKey: 'other-key'),
        },
      );
      expect(apiKeyForPickedRef('prov/m1', cfg), 'file-key');
      expect(apiKeyForPickedRef('other/m1', cfg), 'other-key');
    });

    test('only the first segment names the provider', () {
      final cfg = UserConfig(
        providers: {'a': ProviderConfig(apiKey: 'a-key')},
      );
      expect(apiKeyForPickedRef('a/b/c', cfg), 'a-key');
    });

    test('an unknown provider block is null (registry auth fallback)', () {
      expect(apiKeyForPickedRef('zzz/m1', UserConfig.empty), isNull);
      expect(
        apiKeyForPickedRef(
          'zzz/m1',
          UserConfig(providers: {'prov': ProviderConfig(apiKey: 'k')}),
        ),
        isNull,
      );
    });

    test('a bare model ref tolerates the empty provider id', () {
      final cfg = UserConfig(
        providers: {'': ProviderConfig(apiKey: 'empty-key')},
      );
      expect(apiKeyForPickedRef('m1', cfg), 'empty-key');
      expect(apiKeyForPickedRef('m1', UserConfig.empty), isNull);
    });
  });
}

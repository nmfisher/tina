import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';

/// A [ProviderBuilder] that records every [ProviderInstance] it received and
/// returns a throwaway [FakeProvider]. Lets us assert what the registry handed
/// to the builder without standing up a real provider.
ProviderBuilder _recording(List<ProviderInstance> into) =>
    (ProviderInstance c) {
      into.add(c);
      return FakeProvider(const [], model: c.model);
    };

/// A [ProviderBuilder] that records the attempt and always throws — the
/// "builder itself failed" case (bad endpoint config, constructor crash).
ProviderBuilder _throwing(List<ProviderInstance> into) =>
    (ProviderInstance c) {
      into.add(c);
      throw StateError('builder exploded');
    };

ProviderDescriptor _desc(
  String id, {
  String baseUrl = 'https://example.test',
  List<AuthSource> auth = const [
    AuthSource('TEST_KEY', AuthScheme.bearerToken),
  ],
  Map<String, ModelInfo> models = const {},
  int? requestsPerMinute,
  required ProviderBuilder builder,
}) =>
    ProviderDescriptor(
      id: id,
      name: id,
      authSources: auth,
      defaultBaseUrl: baseUrl,
      builder: builder,
      models: models,
      requestsPerMinute: requestsPerMinute,
    );

/// Registers a [ProviderDecorator] on [r] that appends `"<tag>"` to
/// [into] on every wrap and returns the inner provider unchanged.
void _tagDecorator(ProviderRegistry r, String tag, List<String> into) =>
    r.decorator = (inner) {
      into.add(tag);
      return inner;
    };

void main() {
  group('build failure propagation', () {
    test('a throwing builder propagates unwrapped on build', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _throwing(built)));

      expect(() => r.build('p/m'), throwsStateError);
      expect(built, hasLength(1), reason: 'the builder ran exactly once');
    });

    test('decorator never sees a failed build', () {
      final built = <ProviderInstance>[];
      final wraps = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _throwing(built)));
      _tagDecorator(r, 'wrap', wraps);

      expect(() => r.build('p/m'), throwsStateError);
      expect(wraps, isEmpty,
          reason: 'there is no inner provider to decorate');
    });

    test('unknown provider via build → ProviderRegistryException', () {
      final wraps = <String>[];
      final r = ProviderRegistry(env: {});
      _tagDecorator(r, 'wrap', wraps);

      expect(() => r.build('nosuch/m'),
          throwsA(isA<ProviderRegistryException>()));
      expect(wraps, isEmpty,
          reason: 'resolution fails before anything is built or wrapped');
    });

    test("an empty-string override is handed to the builder verbatim", () {
      // An override of '' is distinct from null: it is passed through as a
      // key (providers construct fine with an empty one — see _buildLimited),
      // so a site wanting the env fallback must pass null instead. Documented
      // here so the distinction stays observable.
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'env-key'})
        ..register(_desc('p', builder: _recording(built)));

      r.build('p/m', apiKeyOverride: '');
      expect(built.single.apiKey, '',
          reason: "'' is handed to the builder verbatim, not swapped for the "
              "env key");
    });

    test('null override falls back to the env-supplied key', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'env-key'})
        ..register(_desc('p', builder: _recording(built)));

      r.build('p/m');
      expect(built.single.apiKey, 'env-key');
    });
  });

  group('per-model maxTokens clamp', () {
    test('an over-cap configured value clamps to the catalog maxOutput', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built), models: const {
          'm': ModelInfo(
              id: 'm', name: 'm', contextWindow: 8192, maxOutput: 4096),
        }));

      r.build('p/m', maxTokens: 32768);
      expect(built.single.maxTokens, 4096,
          reason: 'some endpoints reject max_tokens above the model cap '
              '(e.g. NIM 4096-token models) — never send an over-cap value');
    });

    test('a configured value below maxOutput passes through unchanged', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built), models: const {
          'm': ModelInfo(
              id: 'm', name: 'm', contextWindow: 8192, maxOutput: 4096),
        }));

      r.build('p/m', maxTokens: 1024);
      expect(built.single.maxTokens, 1024,
          reason: 'the clamp is a ceiling, never a floor');
    });

    test('an unknown model id passes through unclamped (never clamp on a guess)',
        () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built)));

      r.build('p/custom-model', maxTokens: 12345);
      expect(built.single.maxTokens, 12345);
    });

    test('building with no explicit maxTokens yields the shared default', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built)));

      r.build('p/m');
      expect(built.single.maxTokens, ProviderRegistry.defaultMaxTokens);
    });

    test('the default clamps to the catalog maxOutput too', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built), models: const {
          'm': ModelInfo(
              id: 'm', name: 'm', contextWindow: 8192, maxOutput: 4096),
        }));

      r.build('p/m');
      expect(built.single.maxTokens, 4096);
    });
  });

  group('pooled build failure propagation', () {
    test('a throwing member builder propagates unwrapped from buildPooled',
        () {
      final built = <ProviderInstance>[];
      final ok = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('good', builder: _recording(ok)))
        ..register(_desc('bad', builder: _throwing(built)));

      expect(() => r.buildPooled(['good/m', 'bad/m']), throwsStateError);
      expect(built, hasLength(1));
      expect(ok, hasLength(1),
          reason: 'members build in order; the failure surfaces as-is');
    });

    test('decorator never wraps a failed buildPooled', () {
      final built = <ProviderInstance>[];
      final wraps = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _throwing(built)));
      _tagDecorator(r, 'wrap', wraps);

      expect(() => r.buildPooled(['p/m']), throwsStateError);
      expect(wraps, isEmpty,
          reason: 'the pool never existed, so nothing is decorated');
    });
  });

  group('decorator interaction with pools', () {
    test('the decorator wraps the pool exactly once, not per member', () async {
      final built = <ProviderInstance>[];
      final wraps = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('a', builder: _recording(built)))
        ..register(_desc('b', builder: _recording(built)))
        ..registerPool(_desc('pool',
            builder: (c) => PooledProvider([
                  // The pool descriptor's builder assembles the members —
                  // buildPooled is the ordinary path; here the members are
                  // prebuilt so the test watches only the decorator.
                  _recording([])(const ProviderInstance(
                    apiKey: 'k',
                    model: 'm',
                    baseUrl: 'https://example.test',
                    maxTokens: 1,
                    streamIdleTimeout: Duration(seconds: 1),
                    requestTimeout: Duration(seconds: 1),
                    authScheme: AuthScheme.none,
                  )),
                ]),
            models: const {
              'm': ModelInfo(
                id: 'm',
                name: 'm',
                contextWindow: 8192,
                maxOutput: 4096,
              ),
            }));
      _tagDecorator(r, 'wrap', wraps);

      final p = r.build('pool/m');
      expect(wraps, ['wrap'],
          reason: 'once for the PooledProvider, not once per member');
      expect(p, isA<PooledProvider>());
    });
  });

  group('per-model maxTokens clamp', () {
    test('a configured cap above the catalog ceiling clamps to maxOutput', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p',
            builder: _recording(built),
            models: const {
              'm': ModelInfo(
                  id: 'm', name: 'm', contextWindow: 8192, maxOutput: 4096),
            }));

      r.build('p/m', maxTokens: 32768);
      expect(built.single.maxTokens, 4096,
          reason: 'some endpoints reject over-cap max_tokens outright');
    });

    test('a configured cap below the ceiling passes through unchanged', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p',
            builder: _recording(built),
            models: const {
              'm': ModelInfo(
                  id: 'm', name: 'm', contextWindow: 200000, maxOutput: 64000),
            }));

      r.build('p/m', maxTokens: 8192);
      expect(built.single.maxTokens, 8192,
          reason: 'the caller asked for less than the model allows');
    });

    test('a model unknown to the catalog passes through unclamped', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built)));

      r.build('p/custom-model', maxTokens: 12345);
      expect(built.single.maxTokens, 12345,
          reason: 'never clamp on a guess — the catalog said nothing');
    });

    test('no explicit maxTokens yields the shared engine default', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built)));

      r.build('p/m');
      expect(built.single.maxTokens, ProviderRegistry.defaultMaxTokens);
    });
  });
}

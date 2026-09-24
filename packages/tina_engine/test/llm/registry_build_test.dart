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
  int? minRequestIntervalMs,
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
      minRequestIntervalMs: minRequestIntervalMs,
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

  group('per-provider spacing precedence + local-endpoint exemption', () {
    test('user min_request_interval_ms beats user requests_per_minute', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(built), requestsPerMinute: 60))
        ..setRequestRate('p', 30) // 60s/30 = 2s spacing
        ..setRequestInterval('p', 250); // must win over the RPM override
      r.build('p/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('https://example.test', 'k')),
        const Duration(milliseconds: 250),
      );
    });

    test('user interval beats the descriptor interval; descriptor interval '
        'beats the descriptor RPM hint', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc(
          'hinted',
          builder: _recording(built),
          requestsPerMinute: 40, // → 1500ms
          minRequestIntervalMs: 300,
        ));
      r.build('hinted/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('https://example.test', 'k')),
        const Duration(milliseconds: 300),
        reason: 'the descriptor interval beats its own RPM hint',
      );

      r.setRequestInterval('hinted', 75);
      r.build('hinted/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('https://example.test', 'k')),
        const Duration(milliseconds: 75),
        reason: 'the user interval beats every descriptor-level knob',
      );
    });

    test('a loopback endpoint is exempt from the registry-wide default', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..rateLimiter.minInterval = const Duration(milliseconds: 1000)
        ..register(_desc(
          'local',
          baseUrl: 'http://localhost:11434',
          builder: _recording(built),
        ));
      r.build('local/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('http://localhost:11434', 'k')),
        Duration.zero,
        reason: 'no hosted per-key limit exists on loopback; spacing there '
            'is pure added latency',
      );
    });

    test('a private-network endpoint is exempt too; the user can opt back in',
        () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..rateLimiter.minInterval = const Duration(milliseconds: 1000)
        ..register(_desc(
          'lan',
          baseUrl: 'http://192.168.1.50:8000',
          builder: _recording(built),
        ));
      r.build('lan/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('http://192.168.1.50:8000', 'k')),
        Duration.zero,
      );

      r.setRequestInterval('lan', 0); // explicit opt back in
      r.build('lan/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('http://192.168.1.50:8000', 'k')),
        Duration.zero,
        reason: 'the explicit 0 override also disables spacing',
      );
    });

    test('a hosted endpoint keeps the global default', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..rateLimiter.minInterval = const Duration(milliseconds: 1000)
        ..register(_desc('hosted', builder: _recording(built)));
      r.build('hosted/m');
      expect(
        r.rateLimiter
            .minIntervalFor(providerQueueKey('https://example.test', 'k')),
        const Duration(milliseconds: 1000),
      );
    });

    test('_isLocalEndpoint matches loopback/private forms only', () {
      // Indirect coverage through the public seam: build a descriptor with no
      // knobs against a 172.16/12 host and confirm the exemption applies,
      // and against a lookalike public host and confirm it does not.
      for (final entry in [
        ('http://10.0.0.5:8000', true),
        ('http://172.16.0.1:8000', true),
        ('http://172.31.255.255:8000', true),
        ('http://172.32.0.1:8000', false),
        ('http://192.168.0.1:8000', true),
        ('http://[::1]:8080', true),
        ('http://localhost:11434', true),
        ('http://example.test', false),
      ]) {
        final (url, expected) = entry;
        final built = <ProviderInstance>[];
        final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
          ..rateLimiter.minInterval = const Duration(milliseconds: 1000)
          ..register(_desc('probe', baseUrl: url, builder: _recording(built)));
        r.build('probe/m');
        final got = r.rateLimiter
            .minIntervalFor(providerQueueKey(url, 'k'));
        expect(got == Duration.zero, expected,
            reason: '$url → ${expected ? "exempt" : "global default"}');
      }
    });

    test('reapplyRequestIntervals: withdraw an override and the queue falls '
        'back to the global default', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..rateLimiter.minInterval = const Duration(milliseconds: 1000)
        ..register(_desc('hosted', builder: _recording(built)))
        ..setRequestInterval('hosted', 150);
      r.build('hosted/m');
      final key = providerQueueKey('https://example.test', 'k');
      expect(r.rateLimiter.minIntervalFor(key),
          const Duration(milliseconds: 150));

      // The apply-on-save path: the override was DELETED from the config, so
      // the registry forgets its in-memory maps and reinstalls from (now
      // empty) overrides — the descriptor has no hint either, so the global
      // default must take over again.
      r.clearRequestOverrides();
      r.reapplyRequestIntervals();
      expect(
        r.rateLimiter.minIntervalFor(key),
        const Duration(milliseconds: 1000),
        reason: 'the withdrawn override must stop shadowing the global',
      );
    });

    test('reapplyRequestIntervals: a changed override re-lands on the '
        'already-built queue', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc(
          'hinted',
          builder: _recording(built),
          requestsPerMinute: 40, // → 1500ms
        ));
      r.build('hinted/m');
      final key = providerQueueKey('https://example.test', 'k');
      expect(r.rateLimiter.minIntervalFor(key),
          const Duration(milliseconds: 1500));

      r.setRequestInterval('hinted', 250);
      r.reapplyRequestIntervals();
      expect(r.rateLimiter.minIntervalFor(key),
          const Duration(milliseconds: 250),
          reason: 'apply-on-save reaches queues that already built');
    });

    test('clearRequestOverrides + reapply keeps surviving overrides, drops '
        'deleted ones', () {
      final built = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..rateLimiter.minInterval = const Duration(milliseconds: 1000)
        ..register(_desc('a', builder: _recording(built)))
        ..register(_desc(
            'b', baseUrl: 'http://b.test', builder: _recording(built)))
        ..setRequestInterval('a', 100)
        ..setRequestInterval('b', 200);
      r.build('a/m');
      r.build('b/m');

      // The apply-on-save sequence for "user deleted a's field, kept b's":
      // forget every override, reinstall the ones the config still declares,
      // then push onto the live queues.
      r.clearRequestOverrides();
      r.setRequestInterval('b', 200);
      r.reapplyRequestIntervals();
      expect(
        r.rateLimiter.minIntervalFor(providerQueueKey('https://example.test', 'k')),
        const Duration(milliseconds: 1000),
        reason: "a's withdrawn override falls back to the global default",
      );
      expect(
        r.rateLimiter.minIntervalFor(providerQueueKey('http://b.test', 'k')),
        const Duration(milliseconds: 200),
        reason: "b's surviving override is reinstalled unchanged",
      );
    });
  });
}

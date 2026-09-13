import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

ProviderDescriptor _descriptor(String id, ProviderBuilder builder) =>
    ProviderDescriptor(
      id: id,
      name: id,
      authSources: const [],
      defaultBaseUrl: 'https://$id.example.test',
      builder: builder,
    );

SpendLedger _ledger() => SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);

Future<List<StreamEvent>> _send(LlmProvider provider) =>
    provider.send(system: 'test', messages: const [], tools: const []).toList();

void main() {
  for (final pooled in [false, true]) {
    for (final firstToFinish in ['a', 'b']) {
      test(
          '${pooled ? 'pool failover' : 'retry'} spend stays with its runtime '
          'when $firstToFinish finishes first', () async {
        final failures = <String, _ControlledProvider>{};
        final registry = ProviderRegistry(env: const {})..maxSendRetries = 1;
        registry.register(_descriptor('worker', (c) {
          final provider = _ControlledProvider(c.model,
              failedTokens: c.model == 'a' ? 100 : 200);
          failures[c.model] = provider;
          return provider;
        }));
        registry
            .register(_descriptor('healthy', (c) => _SuccessProvider(c.model)));
        registry.registerPool(_descriptor(
            'pool',
            (c) => registry.buildPooled(
                  ['worker/${c.model}', 'healthy/${c.model}'],
                )));
        final ledgers = {'a': _ledger(), 'b': _ledger()};
        final aFactory = RuntimeProviderFactory(registry,
            decorator: (p) => MeteringProvider(p, ledgers['a']!));
        final bFactory = RuntimeProviderFactory(registry,
            decorator: (p) => MeteringProvider(p, ledgers['b']!));

        // Subsequent registry mutation must affect neither runtime's policy.
        registry.maxSendRetries = 0;
        registry.decorator = (_) => throw StateError('legacy decorator used');
        final prefix = pooled ? 'pool' : 'worker';
        final providers = {
          'a': aFactory.build('$prefix/a'),
          'b': bFactory.build('$prefix/b'),
        };
        addTearDown(() {
          for (final provider in providers.values) {
            provider.close();
          }
        });
        addTearDown(() {
          for (final failed in failures.values) {
            if (!failed.release.isCompleted) failed.release.complete();
          }
        });
        final pending = {
          for (final entry in providers.entries) entry.key: _send(entry.value),
        };
        await Future.wait(failures.values.map((p) => p.started.future));

        final other = firstToFinish == 'a' ? 'b' : 'a';
        failures[firstToFinish]!.release.complete();
        expect(
            await pending[firstToFinish], isNot(contains(isA<StreamError>())));
        final firstTokens = firstToFinish == 'a' ? 100 : 200;
        expect(ledgers[firstToFinish]!.totalTokens, firstTokens + 10);
        expect(ledgers[other]!.totalTokens, 0);
        // Disposing one finished runtime must not detach the other's recorder.
        providers.remove(firstToFinish)!.close();

        failures[other]!.release.complete();
        expect(await pending[other], isNot(contains(isA<StreamError>())));
        expect(ledgers['a']!.totalTokens, 110);
        expect(ledgers['b']!.totalTokens, 210);
        expect(ledgers['a']!.totalEstimatedTokens, 0);
        expect(ledgers['b']!.totalEstimatedTokens, 0);
      });
    }
  }

  test(
    'provider defaults stay within their runtime and qualified provider',
    () {
      final instances = <ProviderInstance>[];
      final registry = ProviderRegistry(env: const {'OTHER_KEY': 'other-key'})
        ..register(
          _descriptor('p', (c) {
            instances.add(c);
            return _SuccessProvider(c.model);
          }),
        )
        ..register(
          ProviderDescriptor(
            id: 'other',
            name: 'Other',
            authSources: const [
              AuthSource('OTHER_KEY', AuthScheme.bearerToken),
            ],
            defaultBaseUrl: 'https://other.test',
            builder: (c) {
              instances.add(c);
              return _SuccessProvider(c.model);
            },
          ),
        );
      final first = RuntimeProviderFactory(
        registry,
        providerDefaults: const {
          'p': ProviderBuildDefaults(
            apiKey: 'first-key',
            baseUrl: 'https://first.test',
            maxTokens: 321,
            streamIdleTimeout: Duration(seconds: 11),
            requestTimeout: Duration(seconds: 13),
          ),
        },
      );
      final second = RuntimeProviderFactory(
        registry,
        providerDefaults: const {
          'p': ProviderBuildDefaults(
            apiKey: 'second-key',
            baseUrl: 'https://second.test',
          ),
        },
      );
      first.build('p/parent').close();
      first.build('p/child').close();
      second.build('p/child').close();
      first.build('other/child').close();
      registry.build('p/unscoped').close();
      expect(instances.map((c) => c.apiKey), [
        'first-key',
        'first-key',
        'second-key',
        'other-key',
        '',
      ]);
      expect(instances.map((c) => c.baseUrl), [
        'https://first.test',
        'https://first.test',
        'https://second.test',
        'https://other.test',
        'https://p.example.test',
      ]);
      expect(instances[1].maxTokens, 321);
      expect(instances[1].streamIdleTimeout, const Duration(seconds: 11));
      expect(instances[1].requestTimeout, const Duration(seconds: 13));

      first
          .build(
            'p/explicit',
            apiKeyOverride: '',
            baseUrlOverride: 'https://explicit.test',
            maxTokens: 456,
            streamIdleTimeout: const Duration(seconds: 17),
            requestTimeout: const Duration(seconds: 19),
          )
          .close();
      expect(instances.last.apiKey, isEmpty);
      expect(instances.last.baseUrl, 'https://explicit.test');
      expect(instances.last.maxTokens, 456);
      expect(instances.last.streamIdleTimeout, const Duration(seconds: 17));
      expect(instances.last.requestTimeout, const Duration(seconds: 19));
    },
  );

  test('bare model names retain catalog credential resolution', () {
    ProviderInstance? instance;
    final registry = ProviderRegistry(env: const {'P_KEY': 'catalog-key'})
      ..register(
        ProviderDescriptor(
          id: 'p',
          name: 'P',
          authSources: const [AuthSource('P_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://catalog.test',
          models: const {
            'bare': ModelInfo(
              id: 'bare',
              name: 'Bare',
              contextWindow: 10000,
              maxOutput: 1000,
            ),
          },
          builder: (c) {
            instance = c;
            return _SuccessProvider(c.model);
          },
        ),
      );
    RuntimeProviderFactory(
      registry,
      providerDefaults: const {
        'p': ProviderBuildDefaults(
          apiKey: 'runtime-key',
          baseUrl: 'https://runtime.test',
        ),
      },
    ).build('bare').close();
    expect(instance!.apiKey, 'catalog-key');
    expect(instance!.baseUrl, 'https://catalog.test');
  });

  test('factories share endpoint queues and preserve per-instance tuning', () {
    final instances = <ProviderInstance>[];
    final registry = ProviderRegistry(env: const {})
      ..rateLimiter.maxConcurrent = 1
      ..register(_descriptor('p', (c) {
        instances.add(c);
        return _SuccessProvider(c.model);
      }));
    final wrapped = <RateLimitedProvider>[];
    LlmProvider capture(LlmProvider provider) {
      wrapped.add(provider as RateLimitedProvider);
      return provider;
    }

    final first = RuntimeProviderFactory(registry, decorator: capture).build(
      'p/one',
      apiKeyOverride: 'test-key',
      baseUrlOverride: 'https://shared.example.test',
      maxTokens: 123,
      streamIdleTimeout: const Duration(seconds: 9),
      requestTimeout: const Duration(seconds: 7),
    );
    final second = RuntimeProviderFactory(registry, decorator: capture).build(
      'p/two',
      apiKeyOverride: 'test-key',
      baseUrlOverride: 'https://shared.example.test',
    );
    addTearDown(first.close);
    addTearDown(second.close);
    expect(wrapped[0].limiter, same(wrapped[1].limiter));
    expect(wrapped[0].limitKey, wrapped[1].limitKey);
    expect(instances.first.maxTokens, 123);
    expect(instances.first.streamIdleTimeout, const Duration(seconds: 9));
    expect(instances.first.requestTimeout, const Duration(seconds: 7));
  });

  test('failed decoration closes only the newly built provider', () {
    final built = <_SuccessProvider>[];
    final registry = ProviderRegistry(env: const {})
      ..register(_descriptor('p', (c) {
        final provider = _SuccessProvider(c.model);
        built.add(provider);
        return provider;
      }));
    final live = RuntimeProviderFactory(registry).build('p/live');
    addTearDown(live.close);
    final factory = RuntimeProviderFactory(registry,
        decorator: (_) => throw StateError('decoration failed'));
    expect(() => factory.build('p/failing'), throwsStateError);
    expect(built.first.closeCount, 0);
    expect(built.last.closeCount, 1);
  });

  test('failed pool construction releases its earlier members', () {
    final built = _SuccessProvider('good');
    final registry = ProviderRegistry(env: const {})
      ..register(_descriptor('good', (_) => built))
      ..register(_descriptor('bad', (_) => throw StateError('build failed')));
    registry.registerPool(
        _descriptor('pool', (_) => registry.buildPooled(['good/m', 'bad/m'])));
    expect(() => RuntimeProviderFactory(registry).build('pool/m'),
        throwsStateError);
    expect(built.closeCount, 1);
  });
}

class _SuccessProvider extends LlmProvider {
  int closeCount = 0;
  _SuccessProvider(super.model);

  @override
  void close() => closeCount++;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    yield const MessageComplete(
      content: [TextBlock('done')],
      stopReason: 'end_turn',
      usage: TokenUsage(inputTokens: 7, outputTokens: 3),
    );
  }
}

class _ControlledProvider extends _SuccessProvider {
  final int failedTokens;
  final started = Completer<void>();
  final release = Completer<void>();
  int sends = 0;
  _ControlledProvider(super.model, {required this.failedTokens});

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    if (sends++ == 0) {
      started.complete();
      await release.future;
      yield StreamError('retryable failure',
          statusCode: 503,
          retryAfter: Duration.zero,
          usage: TokenUsage(inputTokens: failedTokens, outputTokens: 0));
      return;
    }
    yield* super.send(system: system, messages: messages, tools: tools);
  }
}

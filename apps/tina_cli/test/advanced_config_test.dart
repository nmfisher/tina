import 'dart:io' hide HttpResponse;
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/session.dart';
import 'config_parity_test.dart' show CaptureEndpoint;

const structuredOutputFixture = JsonOutputSchema(name: 'fixture_decision', schema: {
  'type': 'object',
  'properties': {
    'decision': {
      'type': 'string',
      'enum': ['ALLOW', 'DENY']
    }
  },
  'required': ['decision'],
  'additionalProperties': false,
});

void main() {
  test('configured variants supply canvas colors and preserve overrides', () {
    for (final variant in ['dark', 'light']) {
      final config = parseTinaConfig({
        'default': {'model': 'm'},
        'theme': {
          'variant': variant,
          'canvas': {'foreground': '38;5;250'},
          'dialog': {'confirm': '1;7'}
        },
      }).config;
      final theme = resolveTheme(config.theme);
      expect(
          theme.canvas.background, variant == 'dark' ? '48;5;234' : '48;5;255');
      expect(theme.canvas.foreground, '38;5;250');
      expect(theme.dialog.confirm, '1;7');
    }
    expect(resolveTheme({}).canvas.isDefault, true);
  });
  test('reasoning and output settings reach each wire in its own vocabulary',
      () async {
    for (final (id, wire) in [
      ('a', 'anthropic'),
      ('o', 'openai'),
      ('g', 'gemini')
    ]) {
      final result = parseTinaConfig({
        'default': {
          'provider': id,
          'model': 'model',
          'max_tokens': 1000,
          'reasoning_effort': 'high'
        },
        'providers': {
          id: {
            'wire': wire,
            'base_url': 'https://example.invalid',
            'api_key': 'fixture',
            'max_output': 2500,
            if (id == 'o') 'output_token_field': 'max_completion_tokens'
          }
        }
      });
      final endpoint = CaptureEndpoint();
      final provider = configuredProvider(result.config, 'model',
          endpoint: endpoint, environment: {});
      await provider
          .send(system: 'hello', messages: [], tools: []).drain<void>();
      provider.close();
      final body = endpoint.body!;
      switch (wire) {
        case 'anthropic':
          expect(body['max_tokens'], 2500);
          expect(body['thinking'], {'type': 'adaptive'});
          expect(body['output_config'], {'effort': 'high'});
        case 'openai':
          expect(body['max_completion_tokens'], 2500);
          expect(body.containsKey('max_tokens'), false);
          expect(body['reasoning_effort'], 'high');
        case 'gemini':
          expect(body['generationConfig']['maxOutputTokens'], 2500);
          expect(body['generationConfig']['thinkingConfig'],
              {'thinkingLevel': 'HIGH'});
      }
    }
  });
  test('output precedence is provider, model, then global fallback', () {
    for (final (providerOutput, modelOutput, fallback, expected) in [
      (32768, 16384, 8192, 32768),
      (2048, 16384, 8192, 2048),
      (null, 32768, 8192, 32768),
      (null, 2048, 8192, 2048),
      (null, null, 12000, 12000),
      (null, null, null, 8192),
    ]) {
      final config = parseTinaConfig({
        'default': {
          'provider': 'fixture',
          'model': 'model',
          if (fallback != null) 'max_tokens': fallback,
        },
        'providers': {
          'fixture': {
            if (providerOutput != null) 'max_output': providerOutput,
          },
        },
      }, descriptors: [
        ProviderDescriptor(
          id: 'fixture',
          name: 'Fixture',
          wire: ProviderWire.openAiCompatible,
          baseUrl: 'https://example.invalid',
          keyEnvVar: 'FIXTURE_API_KEY',
          keyStyle: ProviderKeyStyle.bearer,
          models: {
            'model': ModelInfo(
              id: 'model',
              name: 'Model',
              contextWindow: 131072,
              supportsTools: true,
              maxOutput: modelOutput,
            ),
          },
        ),
      ]).config;
      expect(
          generationFor(config, 'fixture', 'model').maxOutputTokens, expected,
          reason:
              'provider=$providerOutput model=$modelOutput default=$fallback');
    }
  });
  test('pools resolve explicit model IDs and share configured endpoint limits',
      () {
    final config = parseTinaConfig({
      'default': {'provider': 'pool', 'model': 'default-model'},
      'providers': {
        'pool': {
          'members': ['one/org/model', 'two']
        },
        for (final id in ['one', 'two'])
          id: {
            'wire': 'openai',
            'base_url': 'https://example.invalid',
            'requests_per_minute': 60,
            'min_request_interval_ms': 50
          }
      },
      'limits': {'max_concurrent_requests': 2, 'max_session_tokens': 1000},
      'theme': {
        'variant': 'light',
        'input': {'prompt': '31'}
      }
    }).config;
    final policy = configuredPolicy(config);
    addTearDown(policy.closeSession);
    final targets = policy.targets(config.model);
    expect(targets.map((t) => t.id), ['one/org/model', 'two/default-model']);
    expect(targets.map((t) => t.minInterval.inMilliseconds), [1000, 1000]);
    expect(targets.map((t) => t.maxConcurrent), [2, 2]);
    expect(config.limits.sessionTokens, 1000);
    expect(resolveTheme(config.theme), isNotNull);
  });
  test('saving refuses incompatible generation settings without touching disk',
      () {
    final dir = Directory.systemTemp.createTempSync('config-validation-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/config');
    file.writeAsStringSync('[default]\nprovider="openai"\nmodel="model"\n');
    final original = file.readAsStringSync();
    final doc = ConfigDocument.open(file.path);
    doc.table('default')['thinking_budget'] = 1000;
    expect(doc.save, throwsFormatException);
    expect(file.readAsStringSync(), original);
  });
  test(
      'invalid pool members and negative limits fail before creating providers',
      () {
    expect(
        () => parseTinaConfig({
              'default': {'provider': 'pool', 'model': 'm'},
              'providers': {
                'pool': {
                  'members': ['missing']
                }
              }
            }),
        throwsFormatException);
    expect(
        () => parseTinaConfig({
              'default': {'model': 'm'},
              'limits': {'max_global_tokens': -1}
            }),
        throwsFormatException);
  });
  test('structured_output validates values and reaches the descriptor', () {
    Map<String, dynamic> providers(Map<String, dynamic> table) => {
          'default': {'provider': 'p', 'model': 'm'},
          'providers': {'p': table}
        };
    expect(
        () => parseTinaConfig(providers({
              'wire': 'openai',
              'base_url': 'https://example.invalid',
              'structured_output': 'strict'
            })),
        throwsFormatException);
    final pinned =
        parseTinaConfig(providers({
          'wire': 'openai',
          'base_url': 'https://example.invalid',
          'structured_output': 'json_schema'
        })).config;
    expect(pinned.providers['p']!.structuredOutput,
        OpenAiStructuredOutput.jsonSchema);
    expect(descriptorByIdFor('p', pinned.descriptors)!.structuredOutput,
        OpenAiStructuredOutput.jsonSchema);
    // Unset: null, and the verified-host default decides at construction.
    final unset = parseTinaConfig(providers({
      'wire': 'openai',
      'base_url': 'https://example.invalid',
      'api_key': 'fixture'
    })).config;
    expect(unset.providers['p']!.structuredOutput, isNull);
    expect(descriptorByIdFor('p', unset.descriptors)!.structuredOutput, isNull);
  });
  test('structured_output overrides built-in pins and inherits when unset',
      () {
    List<ProviderDescriptor> descriptorsOf(
            Map<String, dynamic> providersTable) =>
        parseTinaConfig({
          'default': {'provider': 'deepseek', 'model': 'deepseek-chat'},
          'providers': providersTable,
        }).config.descriptors;
    // Config wins over the built-in descriptor, in both directions.
    expect(
        descriptorByIdFor(
            'deepseek',
            descriptorsOf({
              'deepseek': {'structured_output': 'json_schema'}
            }))!.structuredOutput,
        OpenAiStructuredOutput.jsonSchema);
    expect(
        descriptorByIdFor(
            'openai',
            descriptorsOf({
              'openai': {'structured_output': 'json_object'}
            }))!.structuredOutput,
        OpenAiStructuredOutput.jsonObject);
    // Overrides that do not mention it leave the built-in pin in place.
    expect(
        descriptorByIdFor(
            'deepseek',
            descriptorsOf({
              'deepseek': {'base_url': 'https://api.deepseek.com/v1'}
            }))!.structuredOutput,
        OpenAiStructuredOutput.jsonObject);
  });
  test('structured_output and the host default reach the request', () async {
    Future<Map<String, dynamic>?> requestFormat(String? structured) async {
      final endpoint = CaptureEndpoint();
      final result = parseTinaConfig({
        'default': {'provider': 'p', 'model': 'model'},
        'providers': {
          'p': {
            'wire': 'openai',
            'base_url': 'https://example.invalid',
            'api_key': 'fixture',
            if (structured != null) 'structured_output': structured,
          }
        }
      });
      final provider = configuredProvider(result.config, 'model',
          environment: {}, endpoint: endpoint);
      addTearDown(provider.close);
      await (provider as StructuredOutputProvider)
          .sendStructured(
              system: '',
              messages: const [],
              output: structuredOutputFixture)
          .toList();
      return endpoint.body!['response_format'] as Map<String, dynamic>?;
    }

    // Unknown host, unset: loose default through the full config path.
    expect(await requestFormat(null), {'type': 'json_object'});
    // Pinned strict through the same path.
    expect((await requestFormat('json_schema'))!['json_schema'],
        containsPair('strict', true));
  });
  test('web_search validates values and reaches the descriptor', () {
    Map<String, dynamic> providers(Map<String, dynamic> table) => {
          'default': {'provider': 'p', 'model': 'm'},
          'providers': {'p': table}
        };
    expect(
        () => parseTinaConfig(providers({
              'wire': 'openai',
              'base_url': 'https://example.invalid',
              'web_search': 'yes'
            })),
        throwsFormatException);
    // The Anthropic and Gemini wires have no web-search request field.
    expect(
        () => parseTinaConfig(providers({
              'wire': 'anthropic',
              'base_url': 'https://example.invalid',
              'web_search': true
            })),
        throwsFormatException);
    final enabled =
        parseTinaConfig(providers({
          'wire': 'openai',
          'base_url': 'https://example.invalid',
          'web_search': true
        })).config;
    expect(enabled.providers['p']!.webSearch, isTrue);
    expect(descriptorByIdFor('p', enabled.descriptors)!.supportsWebSearch,
        isTrue);
    // Unset on a custom provider: the endpoint was never claimed to
    // support it.
    final unset = parseTinaConfig(providers({
      'wire': 'openai',
      'base_url': 'https://example.invalid',
      'api_key': 'fixture'
    })).config;
    expect(unset.providers['p']!.webSearch, isNull);
    expect(descriptorByIdFor('p', unset.descriptors)!.supportsWebSearch,
        isFalse);
  });
  test('web_search overrides built-in pins and inherits when unset', () {
    List<ProviderDescriptor> descriptorsOf(
            Map<String, dynamic> providersTable) =>
        parseTinaConfig({
          'default': {'provider': 'openai', 'model': 'gpt-4o'},
          'providers': providersTable,
        }).config.descriptors;
    // Config can enable a provider the descriptors left off, and turn a
    // verified one off.
    expect(
        descriptorByIdFor('openai',
            descriptorsOf({
              'openai': {'web_search': true}
            }))!.supportsWebSearch,
        isTrue);
    expect(
        descriptorByIdFor('glm',
            descriptorsOf({
              'glm': {'web_search': false}
            }))!.supportsWebSearch,
        isFalse);
    // An override that does not mention it leaves the built-in pin.
    expect(
        descriptorByIdFor('glm',
            descriptorsOf({
              'glm': {'base_url': 'https://open.bigmodel.cn/api/paas/v4'}
            }))!.supportsWebSearch,
        isTrue);
    // A wire override to a wire without the field clears it.
    expect(
        descriptorByIdFor('glm',
            descriptorsOf({
              'glm': {
                'wire': 'anthropic',
                'base_url': 'https://open.bigmodel.cn/api/paas/v4'
              }
            }))!.supportsWebSearch,
        isFalse);
  });
  test('web_search rides the request tools on the openai wire', () async {
    final endpoint = CaptureEndpoint();
    final result = parseTinaConfig({
      'default': {'provider': 'p', 'model': 'model'},
      'providers': {
        'p': {
          'wire': 'openai',
          'base_url': 'https://example.invalid',
          'api_key': 'fixture',
          'web_search': true,
        }
      }
    });
    final provider = configuredProvider(result.config, 'model',
        environment: {}, endpoint: endpoint);
    await provider
        .send(system: '', messages: const [], tools: const [])
        .drain<void>();
    provider.close();
    final body = endpoint.body!;
    final tools = body['tools'] as List;
    expect(tools.whereType<Map>().map((t) => t['type']).single, 'web_search');
    expect(tools.whereType<Map>().single['web_search'],
        {'enable': true});
  });
}

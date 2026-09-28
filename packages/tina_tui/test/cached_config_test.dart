import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';
import 'config_parity_test.dart' show CaptureEndpoint;

void main() {
  late Directory home;
  late File config;
  setUp(() {
    home = Directory.systemTemp.createTempSync('cached-config-');
    final cache = File('${home.path}/.tina/cache/models.dev.providers.json');
    cache.parent.createSync(recursive: true);
    cache.writeAsStringSync(jsonEncode({
      'discovered': {
        'name': 'Discovered',
        'npm': '@ai-sdk/openai-compatible',
        'api': 'https://fixture.invalid/v1',
        'env': ['SHARED_KEY', 'FALLBACK_KEY'],
        'models': {
          'model': {
            'name': 'Model',
            'tool_call': true,
            'limit': {'context': 100000, 'output': 12000}
          }
        },
      },
      'unsupported': {'npm': 'unknown-wire', 'api': 'https://wrong.invalid'},
      'openai': {
        'npm': '@ai-sdk/openai-compatible',
        'api': 'https://wrong.invalid'
      },
      'invalid': {
        'npm': '@ai-sdk/openai-compatible',
        'api': 'https://user:password@wrong.invalid'
      },
    }));
    config = File('${home.path}/.tina/config')..writeAsStringSync('''
version = 1
[default]
provider = "discovered"
model = "model"
[providers.discovered]
models = ["extra|Extra model"]
disabled_models = ["extra"]
[typesafe]
api_key = "unused"
''');
  });
  tearDown(() => home.deleteSync(recursive: true));
  test('existing config uses cached endpoints, aliases and unioned models',
      () async {
    final loaded = loadTinaConfig(environment: {'HOME': home.path});
    expect(loaded, isA<TinaConfigOk>());
    expect(loaded.config.providerId, 'discovered');
    final descriptor =
        descriptorByIdFor('discovered', loaded.config.descriptors)!;
    expect(descriptor.baseUrl, 'https://fixture.invalid/v1');
    expect(descriptor.models.keys, containsAll(['model', 'extra']));
    expect(descriptor.models['model']!.maxOutput, 12000);
    expect(descriptorByIdFor('openai', loaded.config.descriptors)!.baseUrl,
        isNot('https://wrong.invalid'));
    expect(descriptorByIdFor('unsupported', loaded.config.descriptors), isNull);
    expect(descriptorByIdFor('invalid', loaded.config.descriptors), isNull);
    final before = config.readAsStringSync();
    for (final credentials in [
      {'SHARED_KEY': 'primary', 'FALLBACK_KEY': 'secondary'},
      {'FALLBACK_KEY': 'secondary'},
      {'DISCOVERED_API_KEY': 'normalized'},
    ]) {
      final endpoint = CaptureEndpoint();
      final provider = configuredProvider(loaded.config, 'model',
          endpoint: endpoint, environment: credentials);
      await provider
          .send(system: 'test', messages: [], tools: []).drain<void>();
      provider.close();
      expect(endpoint.headers!['authorization'],
          'Bearer ${credentials.values.first}');
      expect(endpoint.body!['model'], 'model');
    }
    final policy = configuredPolicy(loaded.config);
    expect(policy.targets('model').single.id, 'discovered/model');
    expect(() => policy.targets('extra'), throwsFormatException);
    policy.closeSession();
    final doc = ConfigDocument.open(config.path);
    doc.validate(descriptors: configuredDescriptors({'HOME': home.path}));
    expect(config.readAsStringSync(), before);
  });
  test('config credentials override discovery environment credentials',
      () async {
    final doc = ConfigDocument.open(config.path);
    (doc.table('providers')['discovered'] as Map)['api_key'] = 'config-key';
    final loaded = parseTinaConfig(doc.values,
        descriptors: configuredDescriptors({'HOME': home.path}));
    final endpoint = CaptureEndpoint();
    final provider = configuredProvider(loaded.config, 'model',
        endpoint: endpoint, environment: {'SHARED_KEY': 'environment-key'});
    await provider.send(system: '', messages: [], tools: []).drain<void>();
    provider.close();
    expect(endpoint.headers!['authorization'], 'Bearer config-key');
  });
  test('missing or disabled discovery requires an explicit provider URL', () {
    expect(
        () => loadTinaConfig(
            environment: {'HOME': home.path, 'COCOON_MODELS_DEV': '0'}),
        throwsFormatException);
    File('${home.path}/.tina/cache/models.dev.providers.json')
        .writeAsStringSync('bad cache');
    expect(() => loadTinaConfig(environment: {'HOME': home.path}),
        throwsFormatException);
  });
}

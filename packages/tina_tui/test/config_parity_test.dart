import 'dart:convert';
import 'dart:io' hide HttpResponse;
import 'package:test/test.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tui/tina_tui.dart';

final class CaptureEndpoint implements HttpEndpoint {
  Map<String, String>? headers;
  Map<String, dynamic>? body;
  String? path;
  @override
  Future<HttpResponse> post(String path,
      {required Map<String, String> headers, required List<int> body}) async {
    this.path = path;
    this.headers = headers;
    this.body = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    return const HttpResponse(statusCode: 200);
  }

  @override
  Future<HttpResponse> get(String path,
          {Map<String, String> headers = const {}}) =>
      throw UnimplementedError();
}

void main() {
  late Directory directory;
  late File file;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tina-config-parity-');
    file = File('${directory.path}/config');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
      'custom provider, slash-containing model, display labels and disabled models',
      () {
    file.writeAsStringSync('''
[default]
provider = "local"
model = "vendor/model"
[providers.local]
base_url = "http://localhost:1234/v1"
models = ["vendor/model|Local model", "other"]
disabled_models = ["other"]
[plugins]
enabled = []
''');
    final loaded = loadTinaConfig(path: file.path);
    expect(loaded, isA<TinaConfigOk>());
    final config = loaded.config;
    expect(config.providerId, 'local');
    expect(config.model, 'vendor/model');
    final descriptor = descriptorByIdFor('local', config.descriptors)!;
    expect(descriptor.wire, ProviderWire.openAiCompatible);
    expect(descriptor.models['vendor/model']!.name, 'Local model');
    expect(config.providers['local']!.disabledModels, {'other'});
    expect(config.plugins, legacyProfilePlugins);
    final provider = configuredProvider(config, config.model,
        environment: {'LOCAL_API_KEY': 'env'});
    addTearDown(provider.close);
    expect((provider as OpenAiCompatibleProvider).baseUrl,
        'http://localhost:1234/v1');
  });

  for (final wire in ['anthropic', 'openai', 'gemini']) {
    test('$wire honors configured credential, endpoint and bare model',
        () async {
      final config = parseTinaConfig({
        'default': {'provider': 'custom', 'model': 'test-model'},
        'providers': {
          'custom': {
            'wire': wire,
            'base_url': 'https://custom.example/api',
            'api_key': 'config-secret'
          }
        },
      }).config;
      final endpoint = CaptureEndpoint();
      final provider = configuredProvider(config, config.model,
          environment: {
            'CUSTOM_API_KEY': 'env-secret',
            'TINA_LLM_TOKEN': 'wrong'
          },
          endpoint: endpoint);
      addTearDown(provider.close);
      await provider.send(system: '', messages: [], tools: []).toList();
      final header = wire == 'anthropic'
          ? 'x-api-key'
          : wire == 'gemini'
              ? 'x-goog-api-key'
              : 'authorization';
      expect(endpoint.headers![header],
          wire == 'openai' ? 'Bearer config-secret' : 'config-secret');
      expect(endpoint.headers!.values, isNot(contains('env-secret')));
      if (wire != 'gemini')
        expect(endpoint.body!['model'], 'test-model');
      else
        expect(endpoint.path, contains('test-model'));
    });
  }

  test('Anthropic auth_token uses bearer; api_key uses x-api-key', () async {
    for (final setting in ['auth_token', 'api_key']) {
      final config = parseTinaConfig({
        'default': {'provider': 'anthropic', 'model': 'claude'},
        'providers': {
          'anthropic': {setting: 'configured'}
        },
      }).config;
      final endpoint = CaptureEndpoint();
      final provider = configuredProvider(config, 'claude',
          environment: {}, endpoint: endpoint);
      await provider.send(system: '', messages: [], tools: []).toList();
      expect(
          endpoint.headers![
              setting == 'auth_token' ? 'authorization' : 'x-api-key'],
          setting == 'auth_token' ? 'Bearer configured' : 'configured');
      expect(
          endpoint.headers!.containsKey(
              setting == 'auth_token' ? 'x-api-key' : 'authorization'),
          isFalse);
      provider.close();
    }
  });

  test(
      'built-in override retains catalog; selected Anthropic uses configured endpoint',
      () {
    final config = parseTinaConfig({
      'default': {'provider': 'anthropic', 'model': 'claude'},
      'providers': {
        'anthropic': {
          'wire': 'anthropic',
          'base_url': 'https://proxy.example/prefix'
        }
      },
    }).config;
    expect(
        descriptorByIdFor('anthropic', config.descriptors)!.models, isNotEmpty);
    final provider = configuredProvider(config, 'claude', environment: {})
        as AnthropicProvider;
    addTearDown(provider.close);
    expect((provider.endpoint as IoHttpEndpoint).endpoint,
        'https://proxy.example/prefix');
  });

  test('bad provider fields are refused without echoing secrets', () {
    for (final bad in [
      {'wire': 'invalid', 'api_key': 'private-value'},
      {'base_url': 'ftp://example', 'api_key': 'private-value'},
      {
        'base_url': 'https://example',
        'api_key': ['private-value']
      },
      {
        'base_url': 'https://example',
        'models': [42]
      },
      {
        'base_url': 'https://example',
        'members': ['another']
      },
    ]) {
      expect(
          () => parseTinaConfig({
                'default': {'model': 'x'},
                'providers': {'custom': bad}
              }),
          throwsA(isA<FormatException>().having((e) => e.toString(), 'message',
              isNot(contains('private-value')))));
    }
  });

  test(
      'save preserves unrelated tables and credentials, secures file, detects stale edits',
      () {
    file.writeAsStringSync('''
[default]
model = "old"
[providers.anthropic]
api_key = "preserved-key"
[theme]
variant = "light"
[sessions.jsonl]
root = "/old/store"
[plugins]
enabled = []
''');
    final document = ConfigDocument.open(file.path);
    document.table('default')['model'] = 'new';
    document.save();
    final reloaded = ConfigDocument.open(file.path);
    expect(reloaded.table('default')['model'], 'new');
    expect(reloaded.table('theme')['variant'], 'light');
    expect((reloaded.table('sessions')['jsonl'] as Map)['root'], '/old/store');
    expect((reloaded.table('providers')['anthropic'] as Map)['api_key'],
        'preserved-key');
    expect(
        loadTinaConfig(path: file.path).config.plugins, legacyProfilePlugins);
    if (!Platform.isWindows) expect(file.statSync().mode & 0x1ff, 0x180);
    file.writeAsStringSync('[default]\nmodel="external"\n');
    expect(() => reloaded.save(), throwsStateError);
    expect(file.readAsStringSync(), contains('external'));
  });

  test('invalid edits never replace a working config', () {
    file.writeAsStringSync('[default]\nmodel="valid"\n');
    final before = file.readAsStringSync();
    final document = ConfigDocument.open(file.path);
    document.table('default')['model'] = '';
    expect(() => document.save(), throwsFormatException);
    expect(file.readAsStringSync(), before);
  });
}

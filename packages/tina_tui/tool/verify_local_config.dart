/// Opt-in, offline audit of the actual app reader and wire construction.
/// Does not print credential values, write config/cache files, or call providers.
import 'dart:convert';
import 'dart:io' hide HttpResponse;
import 'package:toml/toml.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tui/tina_tui.dart';

class _Capture implements HttpEndpoint {
  Map<String, String>? headers;
  Map<String, dynamic>? body;
  @override
  Future<HttpResponse> post(String path,
      {required Map<String, String> headers, required List<int> body}) async {
    this.headers = headers;
    this.body = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    return const HttpResponse(statusCode: 200);
  }

  @override
  Future<HttpResponse> get(String path,
          {Map<String, String> headers = const {}}) =>
      throw StateError('network forbidden');
}

Iterable<String> _keys(Map values, [String prefix = '']) sync* {
  for (final entry in values.entries) {
    final name = prefix.isEmpty ? '${entry.key}' : '$prefix.${entry.key}';
    if (entry.value is Map) {
      yield* _keys(entry.value as Map, name);
    } else {
      yield name;
    }
  }
}

Future<void> main(List<String> args) async {
  final path = args.isEmpty ? defaultConfigPath() : args.single;
  final file = File(path);
  final original = file.readAsStringSync();
  final values = TomlDocument.parse(original).toMap();
  final loaded = loadTinaConfig(path: path);
  if (loaded is TinaConfigProblem) throw StateError(loaded.problem);
  final config = loaded.config;
  final policy = configuredPolicy(config);
  final targets = policy.targets(config.model);
  policy.closeSession();
  stdout.writeln('Config: $path');
  stdout.writeln(
      'Default: ${configModelReference(config)}; targets: ${targets.map((t) => t.id).join(', ')}');

  const defaults = {
    'provider',
    'model',
    'max_tokens',
    'reasoning_effort',
    'thinking_budget'
  };
  const providers = {
    'name',
    'wire',
    'base_url',
    'api_key',
    'auth_token',
    'models',
    'disabled_models',
    'members',
    'requests_per_minute',
    'min_request_interval_ms',
    'max_output',
    'reasoning_effort',
    'thinking_budget',
    'output_token_field'
  };
  const limits = {
    'max_global_tokens',
    'max_session_tokens',
    'max_turn_tokens',
    'max_request_tokens',
    'max_sub_agent_tokens',
    'max_sub_agent_depth',
    'max_sub_agent_concurrency',
    'requests_per_minute',
    'min_request_interval_ms',
    'max_concurrent_requests'
  };
  final themeKeys = {
    'theme.variant',
    for (final group in {
      'chat': [
        'user_bar',
        'user_text',
        'agent_text',
        'dim',
        'cyan',
        'green',
        'yellow',
        'red',
        'header',
        'inline_code',
        'code_block',
        'link'
      ],
      'border': ['focus', 'selection'],
      'border.busy': ['rail', 'head'],
      'menu': [
        'bar_highlight',
        'bar_dim',
        'dropdown_selected',
        'dropdown_disabled'
      ],
      'completion': ['dim', 'selected'],
      'dialog': ['confirm'],
      'info_panel': ['dim'],
      'text_panel': ['focused', 'unfocused'],
      'spinner': ['dim'],
      'line_editor': ['dim'],
      'host_message': ['normal', 'dim', 'user', 'warning', 'error', 'success'],
    }.entries)
      for (final key in group.value) 'theme.${group.key}.$key',
  };
  final consumed = <String>[], ignored = <String>[];
  for (final key in _keys(values)) {
    final parts = key.split('.');
    final used = key == 'version' ||
        (parts.length == 2 &&
            parts.first == 'default' &&
            defaults.contains(parts.last)) ||
        (parts.length == 3 &&
            parts.first == 'providers' &&
            providers.contains(parts.last)) ||
        (parts.length == 2 &&
            parts.first == 'limits' &&
            limits.contains(parts.last)) ||
        themeKeys.contains(key) ||
        key == 'plugins.enabled' ||
        key == 'plugins.approval_channel' ||
        key.startsWith('plugins.overrides.');
    (used ? consumed : ignored).add(key);
  }
  stdout.writeln('Consumed keys (${consumed.length}):\n${consumed.join('\n')}');
  stdout.writeln('Ignored keys (${ignored.length}):\n${ignored.join('\n')}');
  for (final entry in config.providers.entries) {
    final id = entry.key, settings = entry.value;
    if (settings.members.isNotEmpty) continue;
    final descriptor = descriptorByIdFor(id, config.descriptors)!;
    final model = id == config.providerId
        ? config.model
        : descriptor.models.keys
                .where((m) => !settings.disabledModels.contains(m))
                .firstOrNull ??
            'offline-probe';
    final endpoint = _Capture();
    final provider =
        configuredProvider(config, model, providerId: id, endpoint: endpoint);
    try {
      await provider.send(
          system: 'offline config verification',
          messages: [],
          tools: []).drain<void>();
      if (endpoint.headers == null || endpoint.body == null)
        throw StateError('request not constructed for $id');
      final configuredKey = settings.authToken?.isNotEmpty == true
          ? settings.authToken
          : settings.apiKey;
      if (configuredKey != null &&
          configuredKey.isNotEmpty &&
          !endpoint.headers!.values
              .any((v) => v == configuredKey || v == 'Bearer $configuredKey')) {
        throw StateError(
            'configured credential did not reach the wire for $id');
      }
      if (descriptor.wire != ProviderWire.gemini &&
          endpoint.body!['model'] != model) {
        throw StateError('model mismatch for $id');
      }
      final prefix = providerEnvPrefix(id);
      stdout.writeln(
          'PASS $id: ${descriptor.wire.name}, credential ${configuredKey?.isNotEmpty == true ? 'from config' : 'from environment or absent'}; '
          'key variables: ${[
        descriptor.keyEnvVar,
        ...descriptor.fallbackKeyEnvVars,
        '${prefix}_API_KEY',
        '${id.toUpperCase()}_API_KEY'
      ].where((s) => s.isNotEmpty).toSet().join(', ')}');
    } finally {
      provider.close();
    }
  }
  // The settings editor must accept the same existing file without changing it.
  ConfigDocument.open(path).validate();
  final workspace = Directory.systemTemp.createTempSync('tina-config-startup-');
  try {
    final app = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: path, workingDirectory: workspace.path));
    try {
      if (app.host.config.model != config.model)
        throw StateError('startup model mismatch');
    } finally {
      app.close();
    }
  } finally {
    workspace.deleteSync(recursive: true);
  }
  if (file.readAsStringSync() != original)
    throw StateError('config changed during verification');
  stdout.writeln(
      'PASS: reader, selected routing, wire credential/model construction, settings validation, and unchanged config. No network requests were made.');
}

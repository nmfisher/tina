/// The `tina plugin` subcommands: list / install / remove / info.
///
/// Routed from `runCli` before the main flag schema (the plugin surface is
/// a subcommand tree, not a flag). The flow follows the design doc:
/// resolve -> fetch -> verify (signature, sha256, embedded ABI stamp,
/// declared stamps) -> manifest consent -> cache -> config record; the
/// engine mounts the active plugin through the existing
/// `--plugin-component` path.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:tina_plugin_registry/tina_plugin_registry.dart';
import 'package:path/path.dart' as p;

/// The global config the registry section lives in (~/.tina/config),
/// mirroring the assembly's default.
String globalPluginRegistryConfigPath() {
  final home = Platform.environment['HOME'];
  return home != null ? p.join(home, '.tina', 'config') : '.tina/config';
}

/// Routes a `tina plugin ...` invocation. Returns null when [args] is not
/// a plugin subcommand (the caller falls through to the main CLI).
Future<int?> runPluginSubcommand(List<String> args,
    {required String globalConfigPath, Directory? pluginCacheDir}) async {
  if (args.isEmpty || args.first != 'plugin') return null;
  final rest = args.skip(1).toList();
  final command = rest.isEmpty ? 'help' : rest.first;
  final flags = _parseFlags(rest.skip(1).toList());

  final cache = PluginCache(
      root: pluginCacheDir ?? Directory(_pluginCacheDir()));
  final config = RegistryConfig(File(globalConfigPath));
  final data = config.read();

  switch (command) {
    case 'list':
      await _list(cache, data, flags);
      return 0;
    case 'install':
      return await _install(cache, config, data, flags);
    case 'remove':
      return await _remove(cache, config, data, flags);
    case 'info':
      return await _info(data, flags);
    case 'help':
    case '--help':
    case '-h':
      _help();
      return 0;
    default:
      stderr.writeln('tina plugin: unknown subcommand "$command"');
      _help();
      return 64;
  }
}

String _pluginCacheDir() {
  final home = Platform.environment['HOME'] ?? '.';
  return p.join(home, '.tina', 'plugins');
}

class _PluginFlags {
  final String? specifier;
  final String? registryUrl;
  final String? registryKey;
  final Set<String> grants;
  final bool force;

  _PluginFlags({
    this.specifier,
    this.registryUrl,
    this.registryKey,
    this.grants = const {},
    this.force = false,
  });
}

_PluginFlags _parseFlags(List<String> argv) {
  String? specifier;
  String? url;
  String? key;
  final grants = <String>{};
  var force = false;
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--grant') {
      grants.add(argv[++i]);
    } else if (arg.startsWith('--grant=')) {
      grants.add(arg.substring('--grant='.length));
    } else if (arg == '--registry') {
      url = argv[++i];
    } else if (arg.startsWith('--registry=')) {
      url = arg.substring('--registry='.length);
    } else if (arg == '--key') {
      key = argv[++i];
    } else if (arg.startsWith('--key=')) {
      key = arg.substring('--key='.length);
    } else if (arg == '--force') {
      force = true;
    } else if (!arg.startsWith('--')) {
      specifier ??= arg;
    }
  }
  return _PluginFlags(
      specifier: specifier, registryUrl: url, registryKey: key, grants: grants, force: force);
}

Future<void> _list(PluginCache cache, RegistryConfigData data, _PluginFlags flags) async {
  final installed = await cache.list();
  stdout.writeln('installed (cache ${cache.root.path}):');
  if (installed.isEmpty) {
    stdout.writeln('  (none)');
  }
  for (final record in installed) {
    final active = data.active == record.name ? ' [active]' : '';
    stdout.writeln('  ${record.name}@${record.version}$active');
    stdout.writeln('    grants: ${record.grants.join(', ')}');
    if (record.denied.isNotEmpty) {
      stdout.writeln('    denied: ${record.denied.join(', ')}');
    }
  }
  final client = _client(data, flags);
  if (client == null) {
    stdout.writeln('registry not configured ([plugin-registry].url)');
    return;
  }
  try {
    final index = await client.fetchIndex();
    stdout.writeln('available (${data.url}):');
    for (final entry in index.entries) {
      final grants = entry.grantStrings().join(', ');
      stdout.writeln(
          '  ${entry.name}@${entry.version} - ${entry.description}');
      stdout.writeln('    capabilities: $grants');
    }
  } on RegistryClientError catch (error) {
    stderr.writeln('registry fetch failed: $error');
  }
}

Future<int> _install(PluginCache cache, RegistryConfig config,
    RegistryConfigData data, _PluginFlags flags) async {
  final specifier = flags.specifier;
  if (specifier == null) {
    stderr.writeln('usage: tina plugin install <name[@version]>');
    return 64;
  }
  final client = _client(data, flags);
  if (client == null) {
    stderr.writeln(
        'registry not configured: set [plugin-registry].url and .key in '
        '${config.configPath.path} (or pass --registry/--key)');
    return 78;
  }
  final pinnedKeyText = flags.registryKey ?? data.key;
  if (pinnedKeyText == null) {
    stderr.writeln('pinned registry key missing: set [plugin-registry].key '
        'or pass --key');
    return 78;
  }
  final Uint8List pinnedKey;
  try {
    pinnedKey = Uint8List.fromList(base64.decode(pinnedKeyText));
  } on FormatException {
    stderr.writeln('pinned registry key is not valid base64');
    return 78;
  }
  Map<String, Object?> entry;
  Uint8List bytes;
  try {
    (entry, bytes) = await resolveAndFetch(client, specifier);
  } catch (error) {
    stderr.writeln('tina plugin: $error');
    return 1;
  }

  final interactive = stdin.hasTerminal;
  final ConsentOutcome outcome;
  if (interactive) {
    stdout.writeln(
        '${entry['name']} ${entry['version']} requests access '
        '(default for every capability is DENY):');
    outcome = runInteractiveConsent(parseEntry(entry), (question) {
      stdout.writeln('');
      stdout.writeln('  ${consentCopy(question.capability)}');
      stdout.write('  Grant? [y/N]: ');
      final line = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      return line == 'y' || line == 'yes';
    });
  } else {
    outcome = runNonInteractiveConsent(parseEntry(entry), flags.grants);
  }
  if (outcome.aborted) {
    stderr.writeln('tina plugin: install aborted - ${outcome.abortReason}');
    return 1;
  }

  final InstallOutcome result;
  try {
    result = await installVerified(
      entry: entry,
      artifactBytes: bytes,
      pinnedPublicKey: pinnedKey,
      cache: cache,
      config: config,
      consent: (_) => outcome,
      activate: true,
    );
  } catch (error) {
    stderr.writeln('tina plugin: verification failed - $error');
    return 1;
  }
  stdout.writeln('installed ${result.name}@${result.version} '
      '(${bytes.length} bytes, sha256 ${_shortDigest(entry, bytes)})');
  stdout.writeln('granted: ${result.grants.join(', ')}');
  if (result.denied.isNotEmpty) {
    stdout.writeln('denied: ${result.denied.join(', ')} (the plugin runs '
        'without them; calls will fail closed)');
  }
  if (result.unenforced.isNotEmpty) {
    stdout.writeln('recorded but NOT enforced by this engine build yet: '
        '${result.unenforced.join(', ')}');
  }
  stdout.writeln('active: ${result.name} - the engine mounts it on its '
      'next launch via --plugin-component');
  return 0;
}

String _shortDigest(Map<String, Object?> entry, Uint8List bytes) {
  final declared = (entry['artifact'] as Map<String, Object?>?)?['sha256'];
  return declared is String ? declared.substring(0, 16) : digestOf(bytes).substring(0, 16);
}

Future<int> _remove(
    PluginCache cache, RegistryConfig config, RegistryConfigData data, _PluginFlags flags) async {
  final name = flags.specifier;
  if (name == null) {
    stderr.writeln('usage: tina plugin remove <name> [--force]');
    return 64;
  }
  if (data.active == name && !flags.force) {
    stderr.writeln(
        '$name is the active plugin; pass --force to remove it (the engine '
        'mount clears on the next launch)');
  }
  await cache.remove(name);
  final next = data..installed = data.installed.where((r) => !r.startsWith('$name@')).toList();
  if (data.active == name && flags.force) {
    next.active = null;
  }
  config.write(next);
  stdout.writeln('removed $name');
  return 0;
}

Future<int> _info(RegistryConfigData data, _PluginFlags flags) async {
  final specifier = flags.specifier;
  if (specifier == null) {
    stderr.writeln('usage: tina plugin info <name[@version]>');
    return 64;
  }
  final client = _client(data, flags);
  if (client == null) {
    stderr.writeln('registry not configured');
    return 78;
  }
  final index = await client.fetchIndex();
  final at = specifier.lastIndexOf('@');
  final entry = at > 0
      ? index.exact(specifier.substring(0, at), specifier.substring(at + 1))
      : index.latest(specifier);
  if (entry == null) {
    stderr.writeln('no registry entry for $specifier');
    return 1;
  }
  final raw = json.decode(
      utf8.decode(await client.fetchIndexRaw())) as Map<String, Object?>;
  final entries = raw['entries'] as List;
  for (final candidate in entries) {
    final map = candidate as Map<String, Object?>;
    if (map['name'] == entry.name && map['version'] == entry.version) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(map));
      return 0;
    }
  }
  return 1;
}

RegistryClient? _client(RegistryConfigData data, _PluginFlags flags) {
  final url = flags.registryUrl ?? data.url;
  final key = flags.registryKey ?? data.key;
  if (url == null || key == null) return null;
  return RegistryClient(url: url);
}

void _help() {
  stdout.writeln('''
usage: tina plugin <subcommand>
  list                       installed and available plugins
  install <name[@version]>   verify + manifest consent + cache + record
                             [--grant <id>]      non-interactive opt-in
                             [--registry <url>] [--key <base64>]
  remove <name> [--force]    remove from the cache and the config
  info <name[@version]>      print the full signed entry''');
}

String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

/// The active plugin's mount info, read from the global config + the
/// cache (used by the engine launcher). Grants are filtered to the ones
/// the running host accepts; parameterized consent-surface grants stay
/// recorded-but-unmounted until the enforcement round.
Future<ActivePluginMount?> activeRegistryPlugin(
    {required String globalConfigPath}) async {
  final data =
      RegistryConfig(File(globalConfigPath)).read();
  final name = data.active;
  if (name == null) return null;
  final cache = PluginCache(root: Directory(_pluginCacheDir()));
  final records = await cache.list();
  for (final record in records) {
    if (record.name == name) {
      return ActivePluginMount(
        name: record.name,
        version: record.version,
        componentPath: record.componentPath,
        grants: record.grants
            .where((g) => hostAcceptedGrants.contains(g))
            .toList(),
        unmountedGrants: record.grants
            .where((g) => consentSurfaceIds.contains(g.split(':').first))
            .toList(),
      );
    }
  }
  return null;
}

class ActivePluginMount {
  const ActivePluginMount({
    required this.name,
    required this.version,
    required this.componentPath,
    required this.grants,
    required this.unmountedGrants,
  });

  final String name;
  final String version;
  final String componentPath;
  final List<String> grants;
  final List<String> unmountedGrants;
}

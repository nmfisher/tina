/// The `tina registry` subcommands: add / remove / list against the
/// static registry site (registry.json + registry.json.minisig +
/// plugins/<name>-<version>.component.wasm; see tool/build_registry_site.sh).
///
/// Trust: the index is minisign-signed against a pinned key (the tina
/// release minisign key by default — the same root install.sh pins),
/// artifacts are sha256+size checked against the signed index, and the
/// manifest-consent flow runs unchanged after verification (provenance
/// is not permission). `tina plugin ...` remains the local
/// content-addressed flow.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:tina_plugin_registry/tina_plugin_registry.dart';

/// The public registry site (nmfisher/tina-registry on Cloudflare Pages).
const String defaultRegistryIndexUrl = 'https://tina-registry.pages.dev';

/// The pinned registry minisign public key: the tina release key (same
/// root as install.sh / minisign.pub). Override for tests/private
/// registries with --minisign-key, TINA_REGISTRY_MINISIGN, or
/// [plugin-registry].minisign_key.
const String defaultRegistryMinisignKey =
    'RWRqiX+wTOaPmS7+JVz0pccep+0NBr6xDpLrf37v054BXCPDnGbpma92';

/// Routes a `tina registry ...` invocation. Returns null when [args] is
/// not a registry subcommand (the caller falls through to the main CLI).
Future<int?> runRegistrySubcommand(List<String> args,
    {required String globalConfigPath, Directory? pluginCacheDir}) async {
  if (args.isEmpty || args.first != 'registry') return null;
  final rest = args.skip(1).toList();
  final command = rest.isEmpty ? 'help' : rest.first;
  final flags = _RegistryFlags.parse(rest.skip(1).toList());

  final cache = PluginCache(
      root: pluginCacheDir ?? Directory(_pluginCacheDir()));
  final config = RegistryConfig(File(globalConfigPath));
  final data = config.read();

  switch (command) {
    case 'add':
      return await _add(cache, config, data, flags);
    case 'remove':
      return await _remove(cache, config, data, flags);
    case 'list':
      await _list(cache, data, flags);
      return 0;
    case 'help':
    case '--help':
    case '-h':
      _help();
      return 0;
    default:
      stderr.writeln('tina registry: unknown subcommand "$command"');
      _help();
      return 64;
  }
}

String _pluginCacheDir() {
  final home = Platform.environment['HOME'] ?? '.';
  return '$home/.tina/plugins';
}

class _RegistryFlags {
  String? name;
  String? version;
  String? indexUrl;
  String? minisignKey;
  final grants = <String>{};
  bool force = false;

  static _RegistryFlags parse(List<String> argv) {
    final flags = _RegistryFlags();
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      String value() => argv[++i];
      if (arg == '--version') {
        flags.version = value();
      } else if (arg.startsWith('--version=')) {
        flags.version = arg.substring('--version='.length);
      } else if (arg == '--index-url') {
        flags.indexUrl = value();
      } else if (arg.startsWith('--index-url=')) {
        flags.indexUrl = arg.substring('--index-url='.length);
      } else if (arg == '--minisign-key') {
        flags.minisignKey = value();
      } else if (arg.startsWith('--minisign-key=')) {
        flags.minisignKey = arg.substring('--minisign-key='.length);
      } else if (arg == '--grant') {
        flags.grants.add(value());
      } else if (arg.startsWith('--grant=')) {
        flags.grants.add(arg.substring('--grant='.length));
      } else if (arg == '--force') {
        flags.force = true;
      } else if (!arg.startsWith('--')) {
        flags.name ??= arg;
      }
    }
    return flags;
  }
}

/// Index URL: --index-url > TINA_REGISTRY_INDEX > [plugin-registry].site_url
/// > the public site constant.
String resolveIndexUrl(_RegistryFlags flags, RegistryConfigData data) =>
    flags.indexUrl ??
    Platform.environment['TINA_REGISTRY_INDEX'] ??
    data.siteUrl ??
    defaultRegistryIndexUrl;

/// Minisign key: --minisign-key > TINA_REGISTRY_MINISIGN >
/// [plugin-registry].minisign_key > the pinned release key. The value is
/// the key file's contents or its bare base64 body; a path to an
/// existing file is read for convenience.
String resolveMinisignKey(_RegistryFlags flags, RegistryConfigData data) {
  final candidate = flags.minisignKey ??
      Platform.environment['TINA_REGISTRY_MINISIGN'] ??
      data.minisignKey ??
      defaultRegistryMinisignKey;
  final file = File(candidate);
  return file.existsSync() ? file.readAsStringSync() : candidate;
}

Future<int> _add(PluginCache cache, RegistryConfig config,
    RegistryConfigData data, _RegistryFlags flags) async {
  final name = flags.name;
  if (name == null) {
    stderr.writeln('usage: tina registry add <name> [--version v] '
        '[--index-url URL] [--minisign-key KEY] [--grant id]');
    return 64;
  }
  final indexUrl = resolveIndexUrl(flags, data);
  final minisignKey = resolveMinisignKey(flags, data);
  final registry = SiteRegistry(
      indexUrl: indexUrl, minisignKeyFileOrBody: minisignKey);

  final VerifiedSiteIndex index;
  try {
    index = await registry.fetchIndex();
  } catch (error) {
    stderr.writeln('tina registry: index rejected - $error');
    return 1;
  }
  final entry =
      flags.version != null ? index.exact(name, flags.version!) : index.latest(name);
  if (entry == null) {
    final known = index.rawEntries
        .where((e) => e['name'] is String)
        .map((e) => '${e['name']}')
        .toSet();
    final catalogOnly = index.rawEntries
        .where((e) => e['name'] == name && !VerifiedSiteIndex.downloadable(e))
        .isNotEmpty;
    if (catalogOnly) {
      stderr.writeln('tina registry: $name is included in the tina binary - '
          'nothing to install');
      return 1;
    }
    stderr.writeln('tina registry: no entry for '
        '${flags.version != null ? '$name@${flags.version}' : name}'
        '${known.isEmpty ? '' : ' (available: ${known.join(', ')})'}');
    return 1;
  }

  final Uint8List bytes;
  try {
    bytes = await registry.fetchArtifact(entry);
  } catch (error) {
    stderr.writeln('tina registry: artifact fetch failed - $error');
    return 1;
  }

  final interactive = stdin.hasTerminal;
  final ConsentOutcome outcome;
  if (interactive) {
    stdout.writeln('${entry['name']} ${entry['version']} requests access '
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
    stderr.writeln('tina registry: install aborted - ${outcome.abortReason}');
    return 1;
  }

  final InstallOutcome result;
  try {
    result = await installVerified(
      entry: entry,
      artifactBytes: bytes,
      // The site index is minisign-verified; per-entry keys do not apply.
      pinnedPublicKey: Uint8List(0),
      cache: cache,
      config: config,
      consent: (_) => outcome,
      activate: true,
      indexSignatureVerified: true,
    );
  } catch (error) {
    stderr.writeln('tina registry: verification failed - $error');
    return 1;
  }
  final digest = (entry['artifact'] as Map)['sha256'] as String? ?? '';
  stdout.writeln('installed ${result.name}@${result.version} '
      '(${bytes.length} bytes, sha256 ${digest.substring(0, digest.length < 16 ? digest.length : 16)})');
  stdout.writeln('index: $indexUrl (minisign verified)');
  stdout.writeln('granted: ${result.grants.isEmpty ? '(none requested)' : result.grants.join(', ')}');
  if (result.denied.isNotEmpty) {
    stdout.writeln('denied: ${result.denied.join(', ')} (the plugin runs '
        'without them; calls will fail closed)');
  }
  if (result.unenforced.isNotEmpty) {
    stdout.writeln('recorded but NOT enforced by this engine build yet: '
        '${result.unenforced.join(', ')}');
  }
  stdout.writeln('active: ${result.name}');
  return 0;
}

Future<int> _remove(
    PluginCache cache, RegistryConfig config, RegistryConfigData data, _RegistryFlags flags) async {
  final name = flags.name;
  if (name == null) {
    stderr.writeln('usage: tina registry remove <name> [--force]');
    return 64;
  }
  if (data.active == name && !flags.force) {
    stderr.writeln('$name is the active plugin; pass --force to remove it');
    return 1;
  }
  await cache.remove(name);
  final next = data
    ..installed = data.installed.where((r) => !r.startsWith('$name@')).toList();
  if (data.active == name && flags.force) {
    next.active = null;
  }
  config.write(next);
  stdout.writeln('removed $name');
  return 0;
}

Future<void> _list(
    PluginCache cache, RegistryConfigData data, _RegistryFlags flags) async {
  final installed = await cache.list();
  stdout.writeln('installed (cache ${cache.root.path}):');
  if (installed.isEmpty) {
    stdout.writeln('  (none)');
  }
  for (final record in installed) {
    final active = data.active == record.name ? ' [active]' : '';
    stdout.writeln('  ${record.name}@${record.version}$active');
    stdout.writeln('    grants: ${record.grants.join(', ')}');
  }

  final indexUrl = resolveIndexUrl(flags, data);
  final registry = SiteRegistry(
      indexUrl: indexUrl,
      minisignKeyFileOrBody: resolveMinisignKey(flags, data));
  stdout.writeln('registry ($indexUrl):');
  try {
    final index = await registry.fetchIndex();
    for (final entry in index.rawEntries) {
      final name = entry['name'] ?? '?';
      final version = entry['version'] ?? '';
      final description = entry['description'] ?? '';
      final downloadable = VerifiedSiteIndex.downloadable(entry);
      final suffix = downloadable ? '' : ' [included in the binary]';
      stdout.writeln('  $name@$version - $description$suffix');
      if (downloadable) {
        final grants = (entry['capabilities'] as List? ?? [])
            .map((c) => c is Map ? '${c['id']}' : '?')
            .join(', ');
        stdout.writeln(
            '    capabilities: ${grants.isEmpty ? '(none)' : grants}');
      }
    }
  } catch (error) {
    stdout.writeln('  (unreachable or rejected: $error)');
  }
}

void _help() {
  stdout.writeln('''
usage: tina registry <subcommand>
  add <name> [--version v]     verify (index minisign + sha256) + consent
                               + install + activate
                               [--index-url URL] [--minisign-key KEY]
                               [--grant <id>]   non-interactive opt-in
  remove <name> [--force]      remove from the cache and the config
  list                         installed + available plugins

index url:  --index-url > TINA_REGISTRY_INDEX >
            [plugin-registry].site_url > $defaultRegistryIndexUrl
minisign:   --minisign-key > TINA_REGISTRY_MINISIGN >
            [plugin-registry].minisign_key > the pinned tina release key''');
}

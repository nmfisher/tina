import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_settings/tina_settings.dart';

const List<String> defaultHomeCaches = [];

final homeCachesSetting = SettingDefinition<List<String>>(
  id: 'tina/tools/home_caches',
  label: 'Shared home caches',
  description: 'Relative host-home cache directories shared read-write with '
      'sandboxed commands. Changes affect subsequent commands. Credential '
      'exclusions still apply. Shared cache contents can be modified.',
  defaultValue: defaultHomeCaches,
  kind: SettingKind.object,
  decode: (raw) {
    if (raw is! List || raw.any((v) => v is! String)) {
      throw const FormatException(
          'Expected a list of relative cache directories');
    }
    final paths = raw.cast<String>();
    validateHomeCaches(paths);
    return List.unmodifiable(paths);
  },
  validate: validateHomeCaches,
);

void validateHomeCaches(List<String> paths) {
  if (paths.toSet().length != paths.length) {
    throw const FormatException('Cache paths cannot repeat');
  }
  for (final value in paths) {
    if (value.isEmpty ||
        p.isAbsolute(value) ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        p.split(value).any((part) => part == '..' || part == '.') ||
        p.normalize(value) != value) {
      throw const FormatException(
          'Cache paths must be normalized relative directories');
    }
    if (paths.any((other) => other != value && p.isWithin(other, value))) {
      throw const FormatException('Cache paths cannot overlap');
    }
  }
}

/// Canonicalize existing ancestors too, so new files inherit the real parent.
String canonicalSandboxPath(String value) {
  var ancestor = p.normalize(p.absolute(value));
  final tail = <String>[];
  while (FileSystemEntity.typeSync(ancestor, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(ancestor);
    if (parent == ancestor) break;
    tail.insert(0, p.basename(ancestor));
    ancestor = parent;
  }
  return p.joinAll([File(ancestor).resolveSymbolicLinksSync(), ...tail]);
}

bool sandboxPathUnder(String child, String parent) {
  final c = p.normalize(child), root = p.normalize(parent);
  return p.equals(c, root) || p.isWithin(root, c);
}

const credentialHomePaths = [
  '.ssh',
  '.aws',
  '.config/gh',
  '.netrc',
  '.npmrc',
  '.docker/config.json',
  '.kube',
  'Library/Keychains',
  '.git-credentials',
  '.cargo/credentials',
  '.cargo/credentials.toml',
  '.m2/settings.xml',
  '.gradle/gradle.properties',
  '.pub-cache/credentials.json',
  '.config/dart/pub-credentials.json',
  '.config/dart/pub-tokens.json',
  'Library/Application Support/dart/pub-credentials.json',
  'Library/Application Support/dart/pub-tokens.json',
  '.cache/huggingface/token',
  '.cache/huggingface/stored_tokens',
  '.tina/config',
  '.tina/approvals',
];

/// Retain both spellings: denying a symlink alone doesn't deny its target.
List<String> sandboxPathAliases(Iterable<String> paths) => {
      for (final value in paths) ...[
        p.normalize(p.absolute(value)),
        canonicalSandboxPath(value),
      ],
    }.toList();

/// A new generation is used after settings changes. Running processes retain
/// their old home and mounts; all generations live until jobs have stopped.
final class SandboxHome {
  SandboxHome(
      {required this.realHome,
      required this.stateRoot,
      List<String> caches = defaultHomeCaches})
      : _caches = List.of(caches) {
    validateHomeCaches(caches);
  }

  final String realHome;
  final String stateRoot;
  List<String> _caches;
  List<String> get caches => List.unmodifiable(_caches);
  final List<Directory> _generations = [];
  final Map<String, RandomAccessFile> _leases = {};
  Directory? _current;
  Map<String, String> _targets = {};
  String? get existingPath => _current?.path;
  List<String> get targets => List.unmodifiable(_targets.values);

  void replace(List<String> caches) {
    validateHomeCaches(caches);
    if (caches.join('\n') == _caches.join('\n')) return;
    _caches = List.of(caches);
    _current = null;
    _targets = {};
  }

  String ensure() {
    if (_current != null) {
      for (final entry in _targets.entries) {
        final target = entry.value;
        if (canonicalSandboxPath(target) != target ||
            canonicalSandboxPath(p.join(realHome, entry.key)) != target) {
          throw FileSystemException('Shared cache target changed', target);
        }
      }
      return _current!.path;
    }
    final parent = Directory(stateRoot)..createSync(recursive: true);
    _cleanAbandoned(parent);
    final home = parent.createTempSync('session-$pid-'); // mkdir with mode 0700
    Directory(p.join(home.path, 'tmp')).createSync();
    final lease = File('${home.path}.lease').openSync(mode: FileMode.write);
    lease.lockSync(FileLock.exclusive);
    _leases[home.path] = lease;
    _generations.add(home);
    final targets = <String, String>{};
    final protected = sandboxPathAliases([
      for (final relative in credentialHomePaths) p.join(realHome, relative),
    ]);
    for (final relative in _caches) {
      final source = p.join(realHome, relative);
      final target = canonicalSandboxPath(source);
      if (sandboxPathUnder(realHome, target) ||
          protected.any((secret) => sandboxPathUnder(target, secret))) {
        throw FileSystemException(
            'Credential paths cannot be shared as caches', source);
      }
      final destination = p.join(home.path, relative);
      Directory(p.dirname(destination)).createSync(recursive: true);
      if (Directory(source).existsSync()) {
        Link(destination).createSync(target);
        targets[relative] = target;
      } else {
        Directory(destination).createSync();
      }
    }
    _targets = targets;
    _current = home;
    return home.path;
  }

  /// A lease lives outside HOME, where the child cannot replace it. Never
  /// touch unowned directories or another session in this process. A crashed
  /// process releases its OS lock; PID reuse conservatively retains its home.
  void _cleanAbandoned(Directory parent) {
    for (final entry in parent.listSync(followLinks: false)) {
      if (entry is! Directory ||
          !p.basename(entry.path).startsWith('session-') ||
          p.basename(entry.path).startsWith('session-$pid-')) continue;
      final leaseFile = File('${entry.path}.lease');
      if (FileSystemEntity.typeSync(leaseFile.path, followLinks: false) !=
          FileSystemEntityType.file) continue;
      RandomAccessFile? lease;
      try {
        lease = leaseFile.openSync(mode: FileMode.append);
        lease.lockSync(FileLock.exclusive);
        entry.deleteSync(recursive: true);
        leaseFile.deleteSync();
      } on FileSystemException {
        // Active session, stale permissions or a concurrent cleanup: retain.
      } finally {
        lease?.closeSync();
      }
    }
  }

  /// Dart recursive deletion unlinks symbolic links rather than traversing them.
  void close() {
    for (final directory in _generations) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      _leases.remove(directory.path)?.closeSync();
      final lease = File('${directory.path}.lease');
      if (lease.existsSync()) lease.deleteSync();
    }
    _generations.clear();
    _current = null;
    _targets = {};
  }
}

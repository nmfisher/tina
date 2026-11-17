import 'dart:io';

import 'package:crypto/crypto.dart';

/// Pinned hermetic reader binaries for tests that certify read-only
/// commands.
///
/// Reader certification only trusts binaries that resolve to
/// `/bin/<name>` or `/usr/bin/<name>` — a deliberate security property
/// (a system-name symlink cannot redirect to something writable). Some
/// CI runner images resolve coreutils through renamed multi-call
/// binaries (an `/usr/bin/rm` that resolves to `…/gnurm`), which makes
/// every positive certification host-dependent: `readOnlyExecutable`
/// correctly returns null there. Tests assert the recognition logic, not
/// the runner's `/usr/bin` topology, so they pin fixture binaries
/// through the same version-pinned hash table production supports
/// (`trustedExecutables`).
class ReaderFixtures {
  ReaderFixtures._(this.directory, this.trusted);

  /// The directory holding one executable per reader name.
  final Directory directory;

  /// The `resolved path → sha256` pin table, ready to pass as
  /// `searchPath`/`trustedExecutables` companions.
  final Map<String, String> trusted;

  /// The directory to put first in a search path.
  String get searchPath => directory.path;

  /// The pinned absolute path of one fixture binary.
  String path(String name) =>
      File('${directory.path}/$name').resolveSymbolicLinksSync();

  /// Creates executable fixtures for [names]. `/bin/chmod` must exist
  /// (Dart cannot set the exec bit itself).
  static Future<ReaderFixtures> create(Iterable<String> names) async {
    final directory =
        await Directory.systemTemp.createTemp('tina-reader-fixtures-');
    final trusted = <String, String>{};
    for (final name in names) {
      final file = File('${directory.path}/$name');
      await file.writeAsString('#!/bin/sh\nexit 0\n');
      final chmod = await Process.run('/bin/chmod', ['+x', file.path]);
      if (chmod.exitCode != 0) {
        throw StateError('cannot chmod fixture $name: ${chmod.stderr}');
      }
      final resolved = file.resolveSymbolicLinksSync();
      trusted[resolved] =
          sha256.convert(await file.readAsBytes()).toString();
    }
    return ReaderFixtures._(directory, trusted);
  }
}

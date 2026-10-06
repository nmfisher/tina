import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_settings/tina_settings.dart';

final writeDirectoriesSetting = SettingDefinition<List<String>>(
  id: 'tina/tools/write_directories',
  label: 'Writable directories',
  description:
      'Directories where file tools may write without further approval. '
      'Approved sandboxed commands can also write here. Select “Allow all writes '
      'in this directory” in a write approval, or enter a JSON array of absolute '
      'directory paths here.',
  defaultValue: const [],
  kind: SettingKind.object,
  decode: (raw) {
    if (raw is! List || raw.any((value) => value is! String)) {
      throw const FormatException('Expected a list of directory paths');
    }
    return List<String>.unmodifiable(raw.cast<String>());
  },
  validate: (paths) {
    if (paths
        .any((value) => !p.isAbsolute(value) || value.contains('\u0000'))) {
      throw const FormatException(
          'Writable directories must be absolute paths');
    }
  },
);

/// Persistent directory grants, separate from exact session file approvals.
final class WriteDirectories {
  List<String> _paths = const [];
  List<String> get paths => _paths;

  // A replaced directory symlink must not redirect a stored OS write grant.
  List<String> get existingPaths => _paths.where((value) {
        try {
          return Directory(value).existsSync() &&
              p.equals(Directory(value).resolveSymbolicLinksSync(), value);
        } on FileSystemException {
          return false;
        }
      }).toList();

  void replace(Iterable<String> paths) {
    _paths = List.unmodifiable({for (final value in paths) _canonical(value)});
  }

  bool allows(String canonicalTarget) => _paths.any((root) =>
      p.equals(canonicalTarget, root) || p.isWithin(root, canonicalTarget));
}

String _canonical(String value) {
  final absolute = p.normalize(p.absolute(value));
  var ancestor = absolute;
  final tail = <String>[];
  while (FileSystemEntity.typeSync(ancestor, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(ancestor);
    if (parent == ancestor) break;
    tail.insert(0, p.basename(ancestor));
    ancestor = parent;
  }
  return p.joinAll([Directory(ancestor).resolveSymbolicLinksSync(), ...tail]);
}

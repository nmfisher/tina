import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_settings/tina_settings.dart';

final readOnlyDirectoriesSetting = SettingDefinition<List<String>>(
  id: 'tina/tools/read_only_directories',
  label: 'Read-only directories',
  description:
      'External directories available to file tools and sandboxed commands. '
      'Verified reader commands can read these paths without execution approval. '
      'Select “Allow all reads in this directory” in an approval prompt, '
      'or enter a JSON array of absolute directory paths here.',
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
          'Read-only directories must be absolute paths');
    }
  },
);

/// Live read access, shared by the approval gate and OS sandbox layout.
/// This list never contributes writable mounts or write approvals.
final class ReadOnlyDirectories {
  List<String> _paths = const [];
  List<String> get paths => _paths;
  List<String> get existingPaths =>
      _paths.where((value) => Directory(value).existsSync()).toList();

  void replace(Iterable<String> paths) {
    _paths = List.unmodifiable({
      for (final value in paths)
        Directory(value).existsSync()
            ? Directory(value).resolveSymbolicLinksSync()
            : p.normalize(value),
    });
  }

  bool allows(String target) =>
      _paths.any((root) => p.equals(target, root) || p.isWithin(root, target));
}

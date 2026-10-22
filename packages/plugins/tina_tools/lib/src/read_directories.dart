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
      'or enter a JSON array of absolute directory paths here. Grants from '
      'session, workspace and global scopes are additive.',
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
  List<String> get existingPaths => _paths.where((value) {
        try {
          return Directory(value).existsSync() &&
              p.equals(Directory(value).resolveSymbolicLinksSync(), value);
        } on FileSystemException {
          return false;
        }
      }).toList();

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

/// A standing answer to read-shaped asks: when set, the command approver
/// approves read-only certified-reader asks without asking again. Scope is
/// the setting's own (session or workspace); the OS sandbox keeps enforcing
/// either way, protected paths stay excluded, and writes never ride this.
final allowReadsOutsideWorkspaceSetting = SettingDefinition<bool>(
  id: 'tina/tools/allow_reads_outside_workspace',
  label: 'Always permit reads outside the workspace',
  description:
      'Answer “always permit reads” to a read-only approval prompt to set '
      'this. Read-only commands (and only reads) then run without asking; '
      'the OS sandbox and protected-path exclusions still apply. Revoke by '
      'clearing this setting (Settings → Permissions).',
  defaultValue: false,
  kind: SettingKind.toggle,
  scopes: const {SettingScope.session, SettingScope.workspace},
  scopeReason: 'A standing read grant is a session or workspace choice; '
      'granting reads everywhere at once is a global decision this setting '
      'deliberately does not offer.',
);

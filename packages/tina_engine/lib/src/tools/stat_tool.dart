import 'dart:io';

import 'sandbox.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Metadata for a single path: type, size, permissions, mtime, and — for a
/// symlink — what it points at. Read-only companion to `ls`; follows a link
/// one level so the caller learns both the link and its target's shape.
class StatTool implements Tool {
  /// Validates the runtime `path` against the project root + tina tree.
  /// Null in tests.
  SandboxedFileSystem? sandbox;

  StatTool({this.sandbox});

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'stat',
        description:
            'Report metadata for one path: type (file/directory/symlink), '
            'size, permission mode, modified time, and the target of a '
            'symlink. Cheaper than a bash `stat` call and needs no approval.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'The file, directory, or symlink to inspect.',
            },
          },
          'required': ['path'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String path;
    try {
      path = requiredString(input, 'path');
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    // The stat can't be covered by the FS seam, so assert the runtime path
    // against the sandbox here. Skipped when sandbox is null. Maps
    // SandboxViolation to a clean error.
    if (sandbox != null) {
      try {
        await sandbox!.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }

    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return ToolResult.error('path does not exist: $path');
    }

    final buf = StringBuffer();
    if (type == FileSystemEntityType.link) {
      final link = Link(path);
      buf.writeln('type: symlink');
      // targetSync returns the stored target even when it dangles; it only
      // throws when the link itself can't be read.
      try {
        buf.writeln('target: ${link.targetSync()}');
      } catch (_) {
        buf.writeln('target: (unreadable)');
      }
      final target = FileSystemEntity.typeSync(path, followLinks: true);
      buf.writeln(
          'resolves to: ${target == FileSystemEntityType.notFound ? '(broken link)' : _describe(target)}');
    } else {
      buf.writeln('type: ${_describe(type)}');
    }
    final stat = FileStat.statSync(path);
    buf.writeln('size: ${stat.size}');
    buf.writeln('permissions: ${_modeString(stat.mode)}');
    buf.writeln('modified: ${stat.modified.toIso8601String()}');
    return ToolResult(buf.toString());
  }
}

String _describe(FileSystemEntityType type) => switch (type) {
      FileSystemEntityType.directory => 'directory',
      FileSystemEntityType.file => 'file',
      FileSystemEntityType.link => 'symlink',
      _ => 'other',
    };

/// `FileStat.mode` carries the OS type bits alongside the permission bits;
/// mask to the 9 permission bits (0777 octal = 0x1FF) and render as `0755`
/// style octal, matching what `ls -l` / `chmod` use.
String _modeString(int mode) =>
    '0${(mode & 0x1FF).toRadixString(8).padLeft(3, '0')}';

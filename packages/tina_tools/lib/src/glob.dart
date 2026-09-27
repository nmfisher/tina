import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('tina_tools.files');

/// Directories never enumerated by [walkFiles]. We don't want to flood
/// results with build artifacts.
const skipDirs = {
  '.git',
  '.dart_tool',
  'node_modules',
  'build',
  '.next',
  'target',
  'dist',
  '.venv',
  'venv',
  '__pycache__',
};

/// File-path glob matcher with `**`-aware path semantics.
///
/// - `*`  matches any sequence of chars **except `/`**.
/// - `**` matches any chars including `/`.
/// - `**/` matches zero or more directory components.
/// - `?`  matches any single non-slash char.
bool fileGlobMatch(String pattern, String input) {
  final sb = StringBuffer(r'^');
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        if (i + 2 < pattern.length && pattern[i + 2] == '/') {
          // `**/` — zero or more directory components
          sb.write(r'(?:[^/]+/)*');
          i += 3;
          continue;
        }
        sb.write(r'.*');
        i += 2;
        continue;
      }
      sb.write(r'[^/]*');
      i++;
    } else if (c == '?') {
      sb.write(r'[^/]');
      i++;
    } else if (r'.+^$(){}[]|\'.contains(c)) {
      sb.write('\\$c');
      i++;
    } else {
      sb.write(c);
      i++;
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString()).hasMatch(input);
}

/// Enumerates the files under [root] as paths relative to [root], walking the
/// directory tree with `dart:io`, skipping well-known build dirs ([skipDirs])
/// and following no symlinks. A root that is itself a file enumerates to just
/// that file.
List<String> walkFiles(String root) {
  if (FileSystemEntity.typeSync(root) == FileSystemEntityType.file) {
    return [p.basename(root)];
  }
  final out = <String>[];
  void walk(Directory d, String prefix) {
    try {
      for (final e in d.listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (skipDirs.contains(name)) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (e is File) {
          out.add(rel);
        } else if (e is Directory) {
          walk(e, rel);
        }
      }
    } catch (e) {
      _log.warning('failed to list ${d.path}, skipping subtree', e);
    }
  }

  walk(Directory(root), '');
  return out;
}

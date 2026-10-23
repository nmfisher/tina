import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Resolve aliases before deciding whether a history belongs to the workspace.
/// Missing leaves are resolved against their nearest existing parent.
String canonicalHistoryPath(String value) {
  final absolute = p.normalize(p.absolute(value));
  try {
    return File(absolute).resolveSymbolicLinksSync();
  } on FileSystemException {
    final parent = p.dirname(absolute);
    if (parent == absolute) return absolute;
    return p.join(canonicalHistoryPath(parent), p.basename(absolute));
  }
}

final class HistoryLocation {
  HistoryLocation({required String workspace, required String store})
      : workspace = canonicalHistoryPath(workspace),
        store = canonicalHistoryPath(store);

  final String workspace;
  final String store;
  String get id => sha256.convert(utf8.encode('$workspace\n$store')).toString();
  Map<String, Object?> toJson() => {'workspace': workspace, 'store': store};
}

/// One small file per visited store avoids lost updates between Tina processes.
/// Discovery reads this catalog only: it never walks arbitrary project folders.
final class HistoryCatalog {
  HistoryCatalog(this.directory);
  final String directory;

  void remember(HistoryLocation location) {
    final root = Directory(directory)..createSync(recursive: true);
    final file = File(p.join(root.path, '${location.id}.json'));
    final encoded = jsonEncode(location.toJson());
    if (file.existsSync() && file.readAsStringSync() == encoded) return;
    final staging = root.createTempSync('.history-');
    try {
      final temp = File(p.join(staging.path, 'location.json'));
      temp.writeAsStringSync(encoded, flush: true);
      temp.renameSync(file.path);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }

  List<HistoryLocation> read() {
    final root = Directory(directory);
    if (!root.existsSync()) return [];
    final locations = <String, HistoryLocation>{};
    for (final entry in root.listSync(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        if (entry.lengthSync() > 16384) continue;
        final value = jsonDecode(entry.readAsStringSync());
        if (value is! Map ||
            value['workspace'] is! String ||
            value['store'] is! String ||
            !p.isAbsolute(value['workspace'] as String) ||
            !p.isAbsolute(value['store'] as String)) continue;
        final location = HistoryLocation(
            workspace: value['workspace'] as String,
            store: value['store'] as String);
        // A moved symlink is a different resource, never an inherited grant.
        if (p.basename(entry.path) != '${location.id}.json') continue;
        locations[location.id] = location;
      } on Object {
        // One stale or damaged registration must not hide other histories.
      }
    }
    return locations.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }
}

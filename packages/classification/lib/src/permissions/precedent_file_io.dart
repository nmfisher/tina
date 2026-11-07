import 'dart:io' as io;

/// The native sync file primitives (see `precedent_store.dart`).
List<String> precedentReadLines(String path) {
  final file = io.File(path);
  if (!file.existsSync()) return const [];
  try {
    return file.readAsLinesSync();
  } catch (_) {
    rethrow;
  }
}

void precedentDelete(String path) {
  final file = io.File(path);
  if (file.existsSync()) file.deleteSync();
}

void precedentWriteAtomic(String path, String contents) {
  final file = io.File(path);
  file.parent.createSync(recursive: true);
  final temporary = io.File('$path.tmp');
  temporary.writeAsStringSync(contents, flush: true);
  temporary.renameSync(path);
}

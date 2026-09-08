import 'dart:io';
import 'package:path/path.dart' as p;
import 'environment_record.dart';
import 'environment_store.dart';
import 'environment_repository.dart';

class FileEnvironmentRepository implements EnvironmentRepository {
  final String projectRoot;
  final EnvironmentTrackingStore tracking;
  FileEnvironmentRepository({required this.projectRoot})
    : tracking = EnvironmentTrackingStore(projectRoot: projectRoot);
  @override
  EnvironmentSnapshot inspect({bool captureRecord = false}) {
    final file = EnvironmentRecord.fileFor(projectRoot);
    final present = EnvironmentRecord.exists(projectRoot);
    return EnvironmentSnapshot(
      recordPresent: present,
      staleReason: tracking.staleReason(),
      recordBytes: captureRecord && file.existsSync()
          ? file.readAsBytesSync()
          : null,
    );
  }

  @override
  bool advanced(EnvironmentSnapshot before) {
    final file = EnvironmentRecord.fileFor(projectRoot);
    if (!file.existsSync()) return false;
    if (!before.recordPresent) return true;
    try {
      final after = file.readAsBytesSync();
      final bytes = before.recordBytes ?? const <int>[];
      if (after.length != bytes.length) return true;
      for (var i = 0; i < after.length; i++) {
        if (after[i] != bytes[i]) return true;
      }
      return false;
    } on FileSystemException {
      return false;
    }
  }

  @override
  void record() => tracking.record();
  @override
  List<String> surveyFolders() {
    const skip = {
      '.dart_tool',
      'build',
      'dist',
      'node_modules',
      'target',
      'vendor',
      'out',
      'obj',
      'coverage',
    };
    return [
      for (final entry in Directory(projectRoot).listSync(followLinks: false))
        if (entry is Directory &&
            !p.basename(entry.path).startsWith('.') &&
            !skip.contains(p.basename(entry.path)))
          p.basename(entry.path),
    ]..sort();
  }
}

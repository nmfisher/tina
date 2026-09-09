import 'dart:io';
import 'package:tina_app/src/environment/environment_record.dart';
import 'package:tina_app/src/environment/environment_store.dart';
import 'package:tina_app/src/environment/environment_repository.dart';

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
}

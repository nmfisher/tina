import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/memory_file_system.dart';

class FailingWrite extends MemoryFileSystem {
  FailingWrite() : super({'target': 'original'});
  @override
  Future<void> writeFile(String path, String content) async {
    await super.writeFile(path, 'partial');
    throw const FileSystemException('write failed');
  }
}

void main() {
  test('failed staged writes are cleaned up without replacing the target',
      () async {
    final fs = FailingWrite();
    await expectLater(atomicWriteFile(fs, 'target', 'new'),
        throwsA(isA<FileSystemException>()));
    expect(fs.files, {'target': 'original'});
  });

  test('byte publication cleans staging directories on success and failure',
      () async {
    final dir = await Directory.systemTemp.createTemp('atomic-bytes-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/target';
    await atomicWriteBytes(path, [0, 255, 42]);
    expect(await File(path).readAsBytes(), [0, 255, 42]);
    final blocked = await Directory('${dir.path}/blocked').create();
    await expectLater(atomicWriteBytes(blocked.path, [1]),
        throwsA(isA<FileSystemException>()));
    expect(dir.listSync().map((e) => e.path).toSet(), {path, blocked.path});
    expect(await File(path).readAsBytes(), [0, 255, 42]);
  });
}

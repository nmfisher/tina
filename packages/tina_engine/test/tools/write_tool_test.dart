import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_file_system.dart';

void main() {
  test('creates a new file and reports the byte count', () async {
    final fs = MemoryFileSystem();
    final res = await WriteTool(fs: fs)
        .execute({'filePath': 'new.txt', 'content': 'hello'});
    expect(res.isError, isFalse);
    expect(res.content, contains('created new.txt'));
    expect(res.content, contains('(5 bytes)'));
    expect(fs.files['new.txt'], 'hello');
  });

  test('overwrites an existing file', () async {
    final fs = MemoryFileSystem({'old.txt': 'old contents'});
    final res = await WriteTool(fs: fs)
        .execute({'filePath': 'old.txt', 'content': 'new contents'});
    expect(res.content, contains('overwrote old.txt'));
    expect(fs.files['old.txt'], 'new contents');
  });

  test('creates parent directories when missing', () async {
    final fs = MemoryFileSystem();
    final res = await WriteTool(fs: fs)
        .execute({'filePath': 'sub/deeper/file.txt', 'content': 'x'});
    expect(res.isError, isFalse);
    expect(fs.files['sub/deeper/file.txt'], 'x');
    expect(fs.directories, contains('sub/deeper'));
  });

  test('a missing filePath param yields an error', () async {
    final res =
        await WriteTool(fs: MemoryFileSystem()).execute({'content': 'x'});
    expect(res.isError, isTrue);
    expect(res.content, contains('filePath is required'));
  });

  test('a missing content param yields an error', () async {
    final res =
        await WriteTool(fs: MemoryFileSystem()).execute({'filePath': 'x.txt'});
    expect(res.isError, isTrue);
    expect(res.content, contains('content is required'));
  });
}

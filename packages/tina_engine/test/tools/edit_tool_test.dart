import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_file_system.dart';

void main() {
  test('replaces a unique occurrence', () async {
    final fs = MemoryFileSystem({'a.txt': 'alpha\nbeta\nalpha'});
    final res = await EditTool(fs: fs).execute({
      'filePath': 'a.txt',
      'oldString': 'beta',
      'newString': 'BETA',
    });
    expect(res.isError, isFalse);
    expect(res.content, contains('1 replacement'));
    expect(fs.files['a.txt'], 'alpha\nBETA\nalpha');
  });

  test('replaceAll substitutes every occurrence', () async {
    final fs = MemoryFileSystem({'a.txt': 'alpha\nbeta\nalpha'});
    final res = await EditTool(fs: fs).execute({
      'filePath': 'a.txt',
      'oldString': 'alpha',
      'newString': 'ALPHA',
      'replaceAll': true,
    });
    expect(res.content, contains('2 replacements'));
    expect(fs.files['a.txt'], 'ALPHA\nbeta\nALPHA');
  });

  test('a non-unique match without replaceAll errors', () async {
    final fs = MemoryFileSystem({'a.txt': 'alpha\nalpha'});
    final res = await EditTool(fs: fs).execute({
      'filePath': 'a.txt',
      'oldString': 'alpha',
      'newString': 'x',
    });
    expect(res.isError, isTrue);
    expect(res.content, contains('matches 2 times'));
  });

  test('identical oldString and newString errors before touching the file',
      () async {
    final fs = MemoryFileSystem({'a.txt': 'keep me'});
    final res = await EditTool(fs: fs).execute({
      'filePath': 'a.txt',
      'oldString': 'keep me',
      'newString': 'keep me',
    });
    expect(res.isError, isTrue);
    expect(res.content, contains('identical'));
    expect(fs.files['a.txt'], 'keep me'); // unchanged
  });

  test('oldString not present errors', () async {
    final fs = MemoryFileSystem({'a.txt': 'hello'});
    final res = await EditTool(fs: fs).execute({
      'filePath': 'a.txt',
      'oldString': 'missing',
      'newString': 'x',
    });
    expect(res.isError, isTrue);
    expect(res.content, contains('oldString not found'));
  });

  test('a missing file errors', () async {
    final res = await EditTool(fs: MemoryFileSystem()).execute({
      'filePath': 'no.txt',
      'oldString': 'a',
      'newString': 'b',
    });
    expect(res.isError, isTrue);
    expect(res.content, contains('File not found'));
  });

  test('missing oldString/newString params error', () async {
    final fs = MemoryFileSystem({'a.txt': 'hello'});
    final res = await EditTool(fs: fs).execute({'filePath': 'a.txt'});
    expect(res.isError, isTrue);
    expect(res.content, contains('oldString and newString are required'));
  });

  test('an empty oldString errors rather than matching everywhere', () async {
    // _countOccurrences short-circuits on an empty needle (returns 0), so an
    // empty oldString surfaces as "not found" instead of a no-op replace.
    final fs = MemoryFileSystem({'a.txt': 'hello world'});
    final res = await EditTool(fs: fs).execute({
      'filePath': 'a.txt',
      'oldString': '',
      'newString': 'x',
    });
    expect(res.isError, isTrue);
    expect(res.content, contains('oldString not found'));
    expect(fs.files['a.txt'], 'hello world'); // unchanged
  });

  test('concurrent edits of different regions both land (per-file lock)',
      () async {
    // Two edits target different tokens in the same file. Without serialization
    // their read-modify-writes interleave at await points and the later write
    // clobbers the earlier (lost update). The per-file lock makes them run one
    // at a time, so both replacements survive.
    final fs = MemoryFileSystem({'shared.txt': 'alpha\nbeta\n'});
    final tool = EditTool(fs: fs)..mutationLock = FileMutationLock();
    final results = await Future.wait([
      tool.execute({
        'filePath': 'shared.txt',
        'oldString': 'alpha',
        'newString': 'ALPHA',
      }),
      tool.execute({
        'filePath': 'shared.txt',
        'oldString': 'beta',
        'newString': 'BETA',
      }),
    ]);
    expect(results.every((r) => !r.isError), isTrue);
    expect(fs.files['shared.txt'], contains('ALPHA'));
    expect(fs.files['shared.txt'], contains('BETA'));
  });
}

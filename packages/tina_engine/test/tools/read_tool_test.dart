import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_file_system.dart';

void main() {
  test('reads a file with 1-indexed line numbers', () async {
    final fs = MemoryFileSystem({'a.txt': 'alpha\nbeta\ngamma'});
    final res = await ReadTool(fs: fs).execute({'filePath': 'a.txt'});
    expect(res.isError, isFalse);
    expect(res.content, contains('1: alpha'));
    expect(res.content, contains('2: beta'));
    expect(res.content, contains('3: gamma'));
  });

  test('offset and limit select a window of lines', () async {
    final fs = MemoryFileSystem({'a.txt': 'one\ntwo\nthree\nfour\nfive'});
    final res = await ReadTool(fs: fs)
        .execute({'filePath': 'a.txt', 'offset': 2, 'limit': 2});
    expect(res.content, contains('2: two'));
    expect(res.content, contains('3: three'));
    expect(res.content, isNot(contains('1: one')));
    expect(res.content, isNot(contains('4: four')));
  });

  test('offset past EOF reports an empty-window note', () async {
    final fs = MemoryFileSystem({'a.txt': 'one\ntwo'});
    final res =
        await ReadTool(fs: fs).execute({'filePath': 'a.txt', 'offset': 99});
    expect(res.isError, isFalse);
    expect(res.content, contains('past EOF'));
  });

  test('a file containing a NUL byte is reported as binary', () async {
    final fs = MemoryFileSystem({'bin.dat': 'ab\u0000cd'});
    final res = await ReadTool(fs: fs).execute({'filePath': 'bin.dat'});
    expect(res.isError, isTrue);
    expect(res.content, contains('binary'));
  });

  test('a missing file yields an error', () async {
    final res =
        await ReadTool(fs: MemoryFileSystem()).execute({'filePath': 'no.txt'});
    expect(res.isError, isTrue);
    expect(res.content, contains('File not found'));
  });

  test('a missing filePath param yields an error', () async {
    final res = await ReadTool(fs: MemoryFileSystem()).execute({});
    expect(res.isError, isTrue);
    expect(res.content, contains('filePath is required'));
  });

  test('truncates output past the byte cap', () async {
    final big = List.generate(2000, (i) => 'line $i ${'x' * 40}').join('\n');
    final fs = MemoryFileSystem({'big.txt': big});
    final res = await ReadTool(fs: fs).execute({'filePath': 'big.txt'});
    expect(res.content, contains('truncated at'));
  });

  test('an empty file reports the empty-window note', () async {
    final fs = MemoryFileSystem({'empty.txt': ''});
    final res = await ReadTool(fs: fs).execute({'filePath': 'empty.txt'});
    expect(res.isError, isFalse);
    expect(res.content, contains('past EOF'));
    expect(res.content, contains('0 lines'));
  });

  test('limit: 0 selects no lines but still notes the remaining count',
      () async {
    final fs = MemoryFileSystem({'a.txt': 'one\ntwo\nthree'});
    final res = await ReadTool(fs: fs)
        .execute({'filePath': 'a.txt', 'limit': 0});
    expect(res.content, isNot(contains('one')));
    expect(res.content, contains('2 more lines'));
  });

  test('line numbers are right-aligned to the width of the last line', () async {
    final text = List.generate(12, (i) => 'line ${i + 1}').join('\n');
    final fs = MemoryFileSystem({'a.txt': text});
    final res = await ReadTool(fs: fs).execute({'filePath': 'a.txt'});
    // width = len('12') = 2 → single-digit lines are space-padded.
    expect(res.content, contains(' 1: line 1'));
    expect(res.content, contains(' 9: line 9'));
    expect(res.content, contains('12: line 12'));
  });
}

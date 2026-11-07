#!/usr/bin/env dart
// Audit a package dir for I/O / non-wasm-capable surface usage.
// Usage: dart io_audit.dart <pkg-dir> [more dirs...]
import 'dart:io';

const ioSymbols = [
  'Platform.', 'File(', 'File.', 'Directory(', 'Directory.', 'FileStat',
  'RandomAccessFile', 'HttpClient(', 'HttpClient.', 'HttpHeaders', 'Process.',
  'Process.run', 'Process.start', 'exitCode', 'exit(', 'sleep(', 'stdout',
  'stderr', 'stdin', 'InternetAddress', 'Signal', 'ProcessSignal',
  'FileSystemEntity', 'Stdin', 'gzip', 'ZLib', 'Socket', 'ServerSocket',
  'FileMode', 'IOSink', 'sleep', 'Random.secure', 'DateTime.now',
  'Stopwatch()', 'Environment', 'pid', 'IOOverrides',
];
const isolateSymbols = ['Isolate.', 'Isolate.spawn', 'SendPort', 'ReceivePort', 'Isolate.run'];
const ffiSymbols = ['DynamicLibrary', 'package:ffi', 'dart:ffi'];

void main(List<String> args) {
  for (final dir in args) {
    final root = Directory(dir);
    if (!root.existsSync()) {
      stderr.writeln('missing: $dir');
      continue;
    }
    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final lines = f.readAsLinesSync();
      final hits = <String>[];
      final imports = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.contains('dart:io') && (l.trimLeft().startsWith('import') || l.trimLeft().startsWith('export'))) {
          imports.add('${i + 1}: ${l.trim()}');
          continue;
        }
        if (l.contains('dart:isolate') && l.trimLeft().startsWith('import')) {
          imports.add('${i + 1}: ${l.trim()}');
        }
        if (l.contains('dart:ffi') && l.trimLeft().startsWith('import')) {
          imports.add('${i + 1}: ${l.trim()}');
        }
        for (final s in [...ioSymbols, ...isolateSymbols, ...ffiSymbols]) {
          if (l.contains(s)) hits.add('${i + 1}: ${s.trim()} :: ${l.trim().substring(0, l.trim().length > 100 ? 100 : l.trim().length)}');
        }
      }
      if (imports.isNotEmpty || hits.isNotEmpty) {
        print('== ${f.path}');
        for (final i in imports) print('   import $i');
        for (final h in hits) print('   $h');
      }
    }
  }
}

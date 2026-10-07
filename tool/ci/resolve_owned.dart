import 'dart:convert';
import 'dart:io';

/// Root analysis/architecture checks need every owned package's resolution,
/// even when only a subset of package test jobs is selected.
Future<void> main() async {
  final policy =
      jsonDecode(File('tool/architecture/policy.json').readAsStringSync())
          as Map;
  final directories = (policy['packagePaths'] as Map).values
      .cast<String>()
      .where((directory) => directory != '.')
      .toList();
  for (var offset = 0; offset < directories.length; offset += 4) {
    final results = await Future.wait(
      directories.skip(offset).take(4).map((directory) async {
        stdout.writeln('pub get in $directory');
        final result = await Process.run('dart', [
          'pub',
          'get',
        ], workingDirectory: directory);
        if (result.exitCode != 0) {
          stderr.writeln('$directory:\n${result.stdout}\n${result.stderr}');
        }
        return result.exitCode;
      }),
    );
    if (results.any((code) => code != 0)) {
      exitCode = 1;
      return;
    }
  }
}

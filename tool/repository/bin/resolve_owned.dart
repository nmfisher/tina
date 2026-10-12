import 'dart:convert';
import 'dart:io';
import 'package:tina_repository_tools/repository.dart';

/// Architecture checks need every owned package's resolution,
/// even when only a subset of package test jobs is selected.
Future<void> main() async {
  final root = await repositoryRoot();
  final policy =
      jsonDecode(
            File('${root.path}/tool/repository/policy.json').readAsStringSync(),
          )
          as Map;
  final directories = (policy['packagePaths'] as Map).values
      .cast<String>()
      .where((directory) => directory != 'tool/repository')
      .toList();
  for (var offset = 0; offset < directories.length; offset += 4) {
    final results = await Future.wait(
      directories.skip(offset).take(4).map((directory) async {
        stdout.writeln('pub get in $directory');
        final result = await Process.run(Platform.resolvedExecutable, [
          'pub',
          'get',
        ], workingDirectory: '${root.path}/$directory');
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

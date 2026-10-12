import 'dart:io';
import 'dart:isolate';

/// Locate the checkout independently of the invoking shell's working directory.
Future<Directory> repositoryRoot() async {
  final library = (await Isolate.resolvePackageUri(
    Uri.parse('package:tina_repository_tools/repository.dart'),
  ))!;
  return Directory.fromUri(library.resolve('../../../'));
}

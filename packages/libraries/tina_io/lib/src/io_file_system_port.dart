/// `dart:io` files behind [FileSystemPort]: the models.dev catalogue cache
/// and future engine file needs. Throwing semantics mirror `dart:io` — the
/// callers catch.
library;

import 'dart:io';

import 'package:tina_core/tina_core.dart';

final class IoFileSystemPort implements FileSystemPort {
  const IoFileSystemPort();

  @override
  Future<String> readText(String path) => File(path).readAsString();

  @override
  Future<void> writeText(String path, String contents) =>
      File(path).writeAsString(contents, flush: true);

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) =>
      Directory(path).create(recursive: recursive);

  @override
  Future<DateTime> lastModified(String path) =>
      File(path).lastModified();
}

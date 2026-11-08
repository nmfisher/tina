import 'file_system.dart';
import 'io_file_system.dart';

/// The native default [FileSystem] (see `default_file_system.dart`).
FileSystem nativeDefaultFileSystem() => const IoFileSystem();

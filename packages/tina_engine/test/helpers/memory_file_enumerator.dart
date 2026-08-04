import 'package:tina_engine/tina_engine.dart';

/// A [FileEnumerator] seeded with a fixed file list per root. Tests drive
/// glob/grep against a known set of relative paths without touching disk or
/// git. Roots not seeded enumerate to empty.
class MemoryFileEnumerator implements FileEnumerator {
  final Map<String, List<String>> filesByRoot;

  MemoryFileEnumerator(this.filesByRoot);

  /// Convenience: every root enumerates to the same list.
  MemoryFileEnumerator.always(List<String> files) : filesByRoot = {'*': files};

  @override
  Future<List<String>> enumerate(String root) async {
    final seeded = filesByRoot[root];
    if (seeded != null) return seeded;
    return filesByRoot['*'] ?? const [];
  }
}

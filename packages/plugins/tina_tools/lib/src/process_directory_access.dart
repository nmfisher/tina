import 'package:path/path.dart' as p;

/// Canonical directory capabilities reviewed for one subprocess tree.
/// Constructing this value does not grant access; only the process gate may
/// install it in ProcessControl.approvedDirectories.
final class ProcessDirectoryAccess {
  const ProcessDirectoryAccess.empty()
      : read = const [],
        write = const [];

  ProcessDirectoryAccess(
      {Iterable<String> read = const [], Iterable<String> write = const []})
      : read = List.unmodifiable(read.toSet().toList()..sort()),
        write = List.unmodifiable(write.toSet().toList()..sort());

  final List<String> read;
  final List<String> write;
  bool get isEmpty => read.isEmpty && write.isEmpty;

  bool covers(ProcessDirectoryAccess other) {
    bool under(String target, Iterable<String> roots) =>
        roots.any((root) => p.equals(target, root) || p.isWithin(root, target));
    return other.read.every((target) => under(target, [...read, ...write])) &&
        other.write.every((target) => under(target, write));
  }

  Map<String, Object?> toJson() => {'read': read, 'write': write};

  factory ProcessDirectoryAccess.fromJson(Object? value) {
    if (value == null) return const ProcessDirectoryAccess.empty();
    if (value is! Map) throw const FormatException('Invalid directory access');
    List<String> paths(String key) {
      final raw = value[key];
      if (raw is! List ||
          raw.length > 32 ||
          raw.any((path) => path is! String || !p.isAbsolute(path))) {
        throw const FormatException('Invalid directory access');
      }
      return raw.cast<String>();
    }

    return ProcessDirectoryAccess(read: paths('read'), write: paths('write'));
  }
}

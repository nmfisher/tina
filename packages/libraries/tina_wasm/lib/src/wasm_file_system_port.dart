/// The wasm filesystem port: `tina_core`'s [FileSystemPort] over WASI
/// preopened directories (`wasi:filesystem/preopens`), the only filesystem
/// a component ever sees.
///
/// A component has no ambient filesystem: the host hands it descriptors
/// for the directories it may touch (the workspace, the config dir). Paths
/// the engine passes ([readText] and friends) are resolved against those
/// preopens; anything that would leave them - including any `..` segment -
/// is refused, because the wasm build must not reach files the host never
/// opened for it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/wasi_filesystem.dart' as fs;

/// The preopened directories, as the host declared them.
final class WasmPreopens {
  WasmPreopens(List<(cm.Owned<fs.TypesDescriptor>, String)> directories)
      : _directories = directories {
    // Longest guest path first, so prefix resolution picks the deepest
    // match ('config/nested' over 'config').
    _directories.sort(
      (a, b) => b.$2.length.compareTo(a.$2.length),
    );
  }

  final List<(cm.Owned<fs.TypesDescriptor>, String)> _directories;

  /// The preopens as the host declared them: (descriptor, guest path).
  List<(cm.Owned<fs.TypesDescriptor>, String)> get directories =>
      List.unmodifiable(_directories);

  /// Resolves [path] against the preopens and returns the descriptor plus
  /// the remaining path under it, or null when [path] belongs to no
  /// preopen. Both 'config/settings.toml' and './config/settings.toml'
  /// resolve; absolute paths resolve when a preopen's guest path matches
  /// their prefix. Paths containing a `..` segment never resolve.
  (cm.Owned<fs.TypesDescriptor>, String)? _resolve(String path) {
    var candidate = path;
    if (candidate.startsWith('/')) {
      // Absolute: match a preopen guest path prefix.
      for (final (descriptor, guestPath) in _directories) {
        if (candidate == guestPath) return (descriptor, '.');
        final root = guestPath.endsWith('/') ? guestPath : '$guestPath/';
        if (candidate.startsWith(root)) {
          return (descriptor, candidate.substring(root.length));
        }
      }
      return null;
    }
    while (candidate.startsWith('./')) {
      candidate = candidate.substring(2);
    }
    if (_hasDotDot(candidate)) return null;
    for (final (descriptor, guestPath) in _directories) {
      if (guestPath == '.' || guestPath.isEmpty) {
        // The working-directory preopen owns every relative path.
        return (descriptor, candidate);
      }
      if (candidate == guestPath) return (descriptor, '.');
      final root = guestPath.endsWith('/') ? guestPath : '$guestPath/';
      if (candidate.startsWith(root)) {
        return (descriptor, candidate.substring(root.length));
      }
    }
    return null;
  }
}

bool _hasDotDot(String path) =>
    path.split('/').any((segment) => segment == '..');

/// [FileSystemPort] over WASI preopens. Throws on missing/unwritable
/// paths like `dart:io` does - callers catch.
final class WasmFileSystemPort implements FileSystemPort {
  WasmFileSystemPort(this._preopens, this._fs);

  final WasmPreopens _preopens;
  final fs.Types _fs;

  @override
  Future<String> readText(String path) async {
    final file = await _open(
      path,
      fs.TypesDescriptorFlags(0).withRead(true),
      fs.TypesOpenFlags(0),
    );
    try {
      final (stream, done) = _fs.methodDescriptorReadViaStream(
        self: file.borrow(),
        offset: 0,
      );
      final chunks = <Uint8List>[];
      var length = 0;
      await for (final chunk in stream) {
        chunks.add(chunk);
        length += chunk.length;
      }
      _throwIfError(await done, path);
      return utf8.decode(_concat(chunks, length));
    } finally {
      file.drop();
    }
  }

  @override
  Future<void> writeText(String path, String contents) async {
    final file = await _open(
      path,
      fs.TypesDescriptorFlags(0).withRead(true).withWrite(true),
      fs.TypesOpenFlags(0).withCreate(true).withTruncate(true),
    );
    try {
      final done = _fs.methodDescriptorWriteViaStream(
        self: file.borrow(),
        data: Stream.value(Uint8List.fromList(utf8.encode(contents))),
        offset: 0,
      );
      _throwIfError(await done, path);
    } finally {
      file.drop();
    }
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    final (root, relative) = _mustResolve(path);
    if (recursive) {
      // WASI creates one directory at a time: walk the segments, treating
      // an existing directory as success like `Directory.create` does.
      var built = '';
      for (final segment in _segments(relative)) {
        built = built.isEmpty ? segment : '$built/$segment';
        final made = await _fs.methodDescriptorCreateDirectoryAt(
          self: root.borrow(),
          path: built,
        );
        switch (made) {
          case cm.OkResult():
            break;
          case cm.ErrorResult(:final value):
            if (value is! fs.TypesErrorCodeExist) _throwFs(path, value);
        }
      }
      return;
    }
    _throwIfError(
      await _fs.methodDescriptorCreateDirectoryAt(
        self: root.borrow(),
        path: relative,
      ),
      path,
    );
  }

  @override
  Future<DateTime> lastModified(String path) async {
    final (root, relative) = _mustResolve(path);
    final stat = await _fs.methodDescriptorStatAt(
      self: root.borrow(),
      pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(true),
      path: relative,
    );
    switch (stat) {
      case cm.OkResult(value: final value):
        final stamp = value.dataModificationTimestamp;
        if (stamp.hasValue) {
          final (:seconds, :nanoseconds) = stamp.requireValue();
          return DateTime.fromMillisecondsSinceEpoch(
            seconds * 1000 + nanoseconds ~/ 1000000,
          );
        }
        throw PathException._('no modification time for $path');
      case cm.ErrorResult(:final value):
        _throwFs(path, value);
    }
  }

  /// Opens [path] under its preopen, following symlinks the way
  /// `dart:io` does for File/Directory operations.
  Future<cm.Owned<fs.TypesDescriptor>> _open(
    String path,
    fs.TypesDescriptorFlags descriptorFlags,
    fs.TypesOpenFlags openFlags,
  ) async {
    final (root, relative) = _mustResolve(path);
    final opened = await _fs.methodDescriptorOpenAt(
      self: root.borrow(),
      pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(true),
      path: relative,
      openFlags: openFlags,
      flags: descriptorFlags,
    );
    switch (opened) {
      case cm.OkResult(:final value):
        return value;
      case cm.ErrorResult(:final value):
        _throwFs(path, value);
    }
  }

  (cm.Owned<fs.TypesDescriptor>, String) _mustResolve(String path) {
    final resolved = _preopens._resolve(path);
    if (resolved == null) {
      throw PathException._(
        'path outside the preopened directories: $path',
      );
    }
    return resolved;
  }

  void _throwIfError(cm.Result<void, fs.TypesErrorCode> result, String path) {
    switch (result) {
      case cm.OkResult():
        break;
      case cm.ErrorResult(:final value):
        _throwFs(path, value);
    }
  }

  Never _throwFs(String path, fs.TypesErrorCode error) {
    throw PathException._('filesystem error for $path: $error');
  }
}

/// Splits [path] into its non-empty segments; `..` segments never reach
/// this far (resolution refuses them).
List<String> _segments(String path) =>
    path.split('/').where((s) => s.isNotEmpty).toList();

Uint8List _concat(List<Uint8List> chunks, int length) {
  final out = Uint8List(length);
  var offset = 0;
  for (final chunk in chunks) {
    out.setAll(offset, chunk);
    offset += chunk.length;
  }
  return out;
}

/// The filesystem failure type: mirrors what `dart:io` throws (a
/// `FileSystemException` with a message) - callers catch generically.
final class PathException implements Exception {
  PathException._(this.message);

  final String message;

  @override
  String toString() => message;
}

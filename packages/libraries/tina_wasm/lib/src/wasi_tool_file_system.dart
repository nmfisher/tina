/// [FileSystem] (the tools' filesystem seam, `tina_tools/portable_tools`)
/// over WASI preopened directories: the wasm engine's file tools read and
/// write the preopened workspace through the real WASI filesystem, with
/// the same confinement the file-system port applies (`..` refused,
/// paths outside preopens refused).
library;

import 'dart:typed_data';

import 'package:tina_tools/portable_tools.dart' as tools;
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/wasi_filesystem.dart' as fs;
import 'package:tina_wasm/src/wasm_file_system_port.dart';

/// The tools' [tools.FileSystem] over [WasmPreopens].
final class WasiToolFileSystem implements tools.FileSystem {
  WasiToolFileSystem(this._preopens, this._fs);

  final WasmPreopens _preopens;
  final fs.Types _fs;

  (cm.Owned<fs.TypesDescriptor>, String) _resolve(String path) {
    final resolved = _preopens.resolve(path);
    if (resolved == null) {
      throw tools.ToolFsException('path outside the preopened directories', path);
    }
    return resolved;
  }

  Future<cm.Owned<fs.TypesDescriptor>> _open(
    String path, {
    bool read = false,
    bool write = false,
    bool create = false,
    bool directory = false,
  }) async {
    final (root, relative) = _resolve(path);
    final opened = await _fs.methodDescriptorOpenAt(
      self: root.borrow(),
      pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(true),
      path: relative,
      openFlags: directory
          ? fs.TypesOpenFlags(0).withDirectory(true)
          : fs.TypesOpenFlags(0),
      flags: fs.TypesDescriptorFlags(0).withRead(read).withWrite(write),
    );
    switch (opened) {
      case cm.OkResult(:final value):
        return value;
      case cm.ErrorResult(:final value):
        throw tools.ToolFsException('open $path failed', path, value.toString());
    }
  }

  @override
  Future<bool> fileExists(String path) async => _exists(path, wantDirectory: false);

  @override
  Future<bool> directoryExists(String path) async =>
      _exists(path, wantDirectory: true);

  Future<bool> _exists(String path, {required bool wantDirectory}) async {
    final (root, relative) = _resolve(path);
    final stat = await _fs.methodDescriptorStatAt(
      self: root.borrow(),
      pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(true),
      path: relative,
    );
    return switch (stat) {
      cm.OkResult(value: final value) when wantDirectory =>
        value.type is fs.TypesDescriptorTypeDirectory,
      cm.OkResult() => true,
      cm.ErrorResult() => false,
    };
  }

  @override
  Future<List<int>> readFileBytes(String path) async {
    final (root, relative) = _resolve(path);
    // Read via the same open + stream + drain the file port uses.
    final file = await _open(path, read: true);
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
      switch (await done) {
        case cm.OkResult():
          break;
        case cm.ErrorResult(:final value):
          throw tools.ToolFsException('read $path failed', path, value.toString());
      }
      final out = Uint8List(length);
      var offset = 0;
      for (final chunk in chunks) {
        out.setAll(offset, chunk);
        offset += chunk.length;
      }
      return out;
    } finally {
      file.drop();
    }
  }

  @override
  Future<String> readFileString(String path) async =>
      String.fromCharCodes(await readFileBytes(path));

  @override
  Future<void> writeFile(String path, String content) async {
    final file = await _open(path, read: true, write: true, create: true);
    try {
      final done = _fs.methodDescriptorWriteViaStream(
        self: file.borrow(),
        data: Stream.value(Uint8List.fromList(content.codeUnits)),
        offset: 0,
      );
      switch (await done) {
        case cm.OkResult():
          break;
        case cm.ErrorResult(:final value):
          throw tools.ToolFsException('write $path failed', path, value.toString());
      }
    } finally {
      file.drop();
    }
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    if (!recursive) {
      final (root, relative) = _resolve(path);
      final made = await _fs.methodDescriptorCreateDirectoryAt(
        self: root.borrow(),
        path: relative,
      );
      _ok(made, path, 'create directory');
      return;
    }
    // Walk the segments like the file port does.
    final (root, relative) = _resolve(path);
    var built = '';
    for (final segment in relative.split('/').where((s) => s.isNotEmpty)) {
      built = built.isEmpty ? segment : '$built/$segment';
      final made = await _fs.methodDescriptorCreateDirectoryAt(
        self: root.borrow(),
        path: built,
      );
      switch (made) {
        case cm.OkResult():
          break;
        case cm.ErrorResult(:final value):
          if (value is! fs.TypesErrorCodeExist) _ok(made, path, 'create directory');
      }
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    // `rename-at` names the old entry from the directory that holds it.
    final fromDir = from.contains('/')
        ? from.substring(0, from.lastIndexOf('/'))
        : '.';
    final parent = await _open(fromDir.isEmpty ? '.' : fromDir,
        read: true, directory: true);
    try {
      final (destRoot, destRelative) = _resolve(to);
      final renamed = await _fs.methodDescriptorRenameAt(
        self: parent.borrow(),
        oldPath: _lastOf(from),
        newDescriptor: destRoot.borrow(),
        newPath: destRelative,
      );
      _ok(renamed, from, 'rename');
    } finally {
      parent.drop();
    }
  }

  String _lastOf(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList().last;

  @override
  Future<void> delete(String path) async {
    final (root, relative) = _resolve(path);
    final removed = await _fs.methodDescriptorUnlinkFileAt(
      self: root.borrow(),
      path: relative,
    );
    switch (removed) {
      case cm.OkResult():
        break;
      case cm.ErrorResult(:final value):
        // A missing file is already deleted, like the native seam.
        if (value is! fs.TypesErrorCodeNoEntry) _ok(removed, path, 'delete');
    }
  }

  @override
  Future<String> createTempFile({required String near}) async {
    // The preopened workspace is one real filesystem: a sibling name is
    // as atomic as the parent allows. Random suffix, capped attempts —
    // same contract as the native implementation.
    final dir = near.substring(0, near.lastIndexOf('/'));
    final base = near.substring(near.lastIndexOf('/') + 1);
    for (var attempt = 0; attempt < 10; attempt++) {
      final name = '.tina-write-$base-$attempt-${DateTime.now().microsecondsSinceEpoch % 1000000}';
      final candidate = dir.isEmpty ? name : '$dir/$name';
      if (!await fileExists(candidate)) return candidate;
    }
    return near;
  }

  void _ok(cm.Result<void, fs.TypesErrorCode> result, String path, String doing) {
    switch (result) {
      case cm.OkResult():
        break;
      case cm.ErrorResult(:final value):
        throw tools.ToolFsException('$doing $path failed', path, value.toString());
    }
  }
}

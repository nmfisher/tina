/// [FileSystem] (the tools' filesystem seam, `tina_tools/portable_tools`)
/// over WASI preopened directories: the wasm engine's file tools read and
/// write the preopened workspace through the real WASI filesystem, with
/// the same confinement the file-system port applies (`..` refused,
/// paths outside preopens refused).
library;

import 'dart:convert';
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
  int _temporarySequence = 0;

  (cm.Owned<fs.TypesDescriptor>, String) _resolve(String path) {
    final resolved = _preopens.resolve(path);
    if (resolved == null) {
      throw tools.ToolFsException(
        'path outside the preopened directories',
        path,
      );
    }
    return resolved;
  }

  Future<cm.Owned<fs.TypesDescriptor>> _open(
    String path, {
    bool read = false,
    bool write = false,
    bool create = false,
    bool truncate = false,
  }) => _withParent(
    path,
    (root, name) => _openAt(
      root,
      name,
      path,
      open: fs.TypesOpenFlags(0).withCreate(create).withTruncate(truncate),
      access: fs.TypesDescriptorFlags(0).withRead(read).withWrite(write),
    ),
  );

  Future<cm.Owned<fs.TypesDescriptor>> _openAt(
    cm.Owned<fs.TypesDescriptor> root,
    String name,
    String path, {
    required fs.TypesOpenFlags open,
    required fs.TypesDescriptorFlags access,
  }) async {
    final opened = await _fs.methodDescriptorOpenAt(
      self: root.borrow(),
      pathFlags: fs.TypesPathFlags(0),
      path: name,
      openFlags: open,
      flags: access,
    );
    switch (opened) {
      case cm.OkResult(:final value):
        return value;
      case cm.ErrorResult(:final value):
        throw tools.ToolFsException(
          'open $path failed',
          path,
          value.toString(),
        );
    }
  }

  // Walk using directory descriptors and never follow project symlinks. Each
  // operation stays bound to the directories it opened even if a name moves.
  Future<T> _withParent<T>(
    String path,
    Future<T> Function(cm.Owned<fs.TypesDescriptor>, String) use, {
    bool createParents = false,
  }) async {
    final (root, relative) = _resolve(path);
    final parts = relative.split('/');
    var parent = root;
    try {
      for (final segment in parts.take(parts.length - 1)) {
        if (createParents) {
          await _createAt(parent, segment, path, existOkay: true);
        }
        final next = await _openAt(
          parent,
          segment,
          path,
          open: fs.TypesOpenFlags(0).withDirectory(true),
          access: fs.TypesDescriptorFlags(0).withRead(true),
        );
        if (!identical(parent, root)) parent.drop();
        parent = next;
      }
      return await use(parent, parts.last);
    } finally {
      if (!identical(parent, root)) parent.drop();
    }
  }

  @override
  Future<bool> fileExists(String path) async =>
      _exists(path, wantDirectory: false);

  @override
  Future<bool> directoryExists(String path) async =>
      _exists(path, wantDirectory: true);

  Future<bool> _exists(String path, {required bool wantDirectory}) async {
    try {
      return await _withParent(path, (parent, name) async {
        final stat = await _fs.methodDescriptorStatAt(
          self: parent.borrow(),
          pathFlags: fs.TypesPathFlags(0),
          path: name,
        );
        return switch (stat) {
          cm.OkResult(:final value) when wantDirectory =>
            value.type is fs.TypesDescriptorTypeDirectory,
          cm.OkResult(:final value) =>
            value.type is fs.TypesDescriptorTypeRegularFile,
          cm.ErrorResult() => false,
        };
      });
    } on tools.ToolFsException {
      return false;
    }
  }

  @override
  Future<List<int>> readFileBytes(String path) async {
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
          throw tools.ToolFsException(
            'read $path failed',
            path,
            value.toString(),
          );
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
      utf8.decode(await readFileBytes(path));

  @override
  Future<void> writeFile(String path, String content) async {
    final file = await _open(path, write: true, create: true, truncate: true);
    try {
      final done = _fs.methodDescriptorWriteViaStream(
        self: file.borrow(),
        data: Stream.value(utf8.encode(content)),
        offset: 0,
      );
      switch (await done) {
        case cm.OkResult():
          break;
        case cm.ErrorResult(:final value):
          throw tools.ToolFsException(
            'write $path failed',
            path,
            value.toString(),
          );
      }
    } finally {
      file.drop();
    }
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) =>
      _withParent(
        path,
        (root, name) => _createAt(root, name, path, existOkay: recursive),
        createParents: recursive,
      );

  Future<void> _createAt(
    cm.Owned<fs.TypesDescriptor> root,
    String name,
    String path, {
    required bool existOkay,
  }) async {
    final made = await _fs.methodDescriptorCreateDirectoryAt(
      self: root.borrow(),
      path: name,
    );
    if (made case cm.ErrorResult(value: fs.TypesErrorCodeExist())
        when existOkay)
      return;
    _ok(made, path, 'create directory');
  }

  @override
  Future<void> rename(String from, String to) => _withParent(
    from,
    (source, oldName) => _withParent(to, (destination, newName) async {
      final renamed = await _fs.methodDescriptorRenameAt(
        self: source.borrow(),
        oldPath: oldName,
        newDescriptor: destination.borrow(),
        newPath: newName,
      );
      _ok(renamed, from, 'rename');
    }),
  );

  @override
  Future<void> delete(String path) => _withParent(path, (root, name) async {
    final removed = await _fs.methodDescriptorUnlinkFileAt(
      self: root.borrow(),
      path: name,
    );
    switch (removed) {
      case cm.OkResult():
        break;
      case cm.ErrorResult(:final value):
        // A missing file is already deleted, like the native seam.
        if (value is! fs.TypesErrorCodeNoEntry) _ok(removed, path, 'delete');
    }
  });

  @override
  Future<String> createTempFile({required String near}) async {
    // Reserve a sibling atomically so only this operation owns its cleanup.
    final slash = near.lastIndexOf('/');
    final prefix = slash >= 0 ? near.substring(0, slash + 1) : '';
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var attempt = 0; attempt < 10; attempt++) {
      final candidate = '$prefix.tina-write-$stamp-${_temporarySequence++}';
      final opened = await _withParent(
        candidate,
        (root, name) => _fs.methodDescriptorOpenAt(
          self: root.borrow(),
          pathFlags: fs.TypesPathFlags(0),
          path: name,
          openFlags: fs.TypesOpenFlags(0).withCreate(true).withExclusive(true),
          flags: fs.TypesDescriptorFlags(0).withWrite(true),
        ),
      );
      switch (opened) {
        case cm.OkResult(:final value):
          value.drop();
          return candidate;
        case cm.ErrorResult(:final value):
          if (value is! fs.TypesErrorCodeExist) {
            throw tools.ToolFsException(
              'cannot reserve temporary file',
              candidate,
              value.toString(),
            );
          }
      }
    }
    throw tools.ToolFsException('cannot reserve temporary file', near);
  }

  void _ok(
    cm.Result<void, fs.TypesErrorCode> result,
    String path,
    String doing,
  ) {
    switch (result) {
      case cm.OkResult():
        break;
      case cm.ErrorResult(:final value):
        throw tools.ToolFsException(
          '$doing $path failed',
          path,
          value.toString(),
        );
    }
  }
}

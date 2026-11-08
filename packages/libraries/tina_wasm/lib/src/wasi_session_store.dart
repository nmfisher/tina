/// The wasm engine's session store: the `SessionStoreApi` contract over
/// one JSON Lines file inside a preopen — the portable twin of the
/// sqlite store, with the same slice semantics (strictly increasing
/// order, `seq` runs 0, 1, 2, …).
///
/// Reads and writes are in-memory: the file is loaded at open (a missing
/// file is an empty store) and [flush] writes the whole log back through
/// the WASI filesystem. The persistence plugin's calls are synchronous
/// (they run inside the loop's persistence callbacks), so the flush
/// belongs to the composition root's shutdown — after the assembly has
/// closed its plugins and before the component's export returns, the
/// same place stdout drains.
///
/// Line shapes (one JSON object per line, append order is the truth):
///   {"t":"marker","at":...,"id":...,"title":...,"model":...,"details":...}
///   {"t":"entry","at":...,"id":...,"seq":n,"entry":{...}}
///   {"t":"details","at":...,"id":...,"model":...,"details":{...}}
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:tina_core/tina_core.dart';
import 'package:tina_persistence/session_store_api.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/wasi_filesystem.dart' as fs;
import 'package:tina_wasm/src/wasm_file_system_port.dart';

final class WasiSessionStore implements SessionStoreApi {
  /// Opens (or starts) the store at guest [path]: every line of an
  /// existing file is loaded; a missing file starts empty.
  static Future<WasiSessionStore> open(
    String path,
    WasmPreopens preopens,
    fs.Types fsTypes,
  ) async {
    final lines = <Map<String, Object?>>[];
    final file = WasiToolFile(preopens, fsTypes);
    if (await file.fileExists(path)) {
      final bytes = await file.readFileBytes(path);
      for (final line in utf8.decode(bytes).split('\n')) {
        if (line.trim().isEmpty) continue;
        // The flush strips the in-memory ordering key; file order is the
        // truth, so keys are reassigned at load.
        lines.add({
          '_key': lines.length + 1,
          ...jsonDecode(line) as Map<String, Object?>,
        });
      }
    }
    return WasiSessionStore._(path, preopens, fsTypes, lines);
  }

  @override
  final String file;

  final WasmPreopens _preopens;
  final fs.Types _fs;
  final List<Map<String, Object?>> _lines;

  /// The next ordering key (file order at load, then increments).
  int _key;

  WasiSessionStore._(this.file, this._preopens, this._fs, this._lines)
      : _key = _lines.length;

  bool _closed = false;

  void _checkOpen() {
    if (_closed) {
      throw SessionStoreException('session store $file is closed');
    }
  }

  Map<String, Object?> _at() =>
      {'at': DateTime.now().toUtc().toIso8601String(), '_key': ++_key};

  @override
  int createSession(String id,
      {String? title,
      String? model,
      SessionDetails? details,
      List<SessionEntry> entries = const []}) {
    _checkOpen();
    if (_markerOf(id) != null) {
      throw SessionStoreException(
          'session $id already exists; resume it instead');
    }
    final base = _at();
    final key = base['_key'] as int;
    _lines.add({
      ...base,
      't': 'marker',
      'id': id,
      if (title != null) 'title': title,
      if (model != null) 'model': model,
      if (details != null) 'details': details.toJson(),
    });
    _appendEntries(id, entries, base);
    return key;
  }

  void _appendEntries(
      String id, List<SessionEntry> entries, Map<String, Object?> base) {
    for (final entry in entries) {
      _lines.add({
        ..._at(),
        't': 'entry',
        'id': id,
        'seq': entry.seq,
        'entry': entry.toJson(),
      });
    }
  }

  @override
  void append(String sessionId, List<SessionEntry> entries) {
    _checkOpen();
    if (_markerOf(sessionId) == null) {
      throw SessionStoreException('session $sessionId is not registered');
    }
    _appendEntries(sessionId, entries, const {});
  }

  @override
  void updateDetails(String sessionId, SessionDetails details,
      {String? model}) {
    _checkOpen();
    if (_markerOf(sessionId) == null) {
      throw SessionStoreException('session $sessionId is not registered');
    }
    _lines.add({
      ..._at(),
      't': 'details',
      'id': sessionId,
      if (model != null) 'model': model,
      'details': details.toJson(),
    });
  }

  Map<String, Object?>? _markerOf(String id) {
    Map<String, Object?>? found;
    for (final line in _lines) {
      if (line['t'] == 'marker' && line['id'] == id) found = line;
    }
    return found;
  }

  Map<String, Object?>? _lastDetailsOf(String id) {
    Map<String, Object?>? found;
    for (final line in _lines) {
      if (line['id'] == id && (line['t'] == 'details')) found = line;
    }
    return found;
  }

  @override
  List<StoredSession> list() {
    _checkOpen();
    final order = <String>[];
    final markers = <String, Map<String, Object?>>{};
    final counts = <String, int>{};
    final lastKeys = <String, int>{};
    var lastModel = <String, String?>{};
    for (final line in _lines) {
      final id = line['id'] as String?;
      if (id == null) continue;
      if (line['t'] == 'marker' && !markers.containsKey(id)) {
        markers[id] = line;
        order.add(id);
      }
      lastKeys[id] = (line['_key'] as num?)?.toInt() ?? lastKeys[id] ?? 0;
      counts[id] = (counts[id] ?? 0) + (line['t'] == 'entry' ? 1 : 0);
      if (line['model'] is String) lastModel[id] = line['model'] as String;
    }
    return [
      for (final id in order)
        StoredSession(
          id: id,
          registryKey: (markers[id]!['_key'] as num).toInt(),
          lastActivityKey: lastKeys[id],
          entries: counts[id] ?? 0,
          title: markers[id]!['title'] as String?,
          model: lastModel[id] ?? markers[id]!['model'] as String?,
          details: _detailsOf(markers[id]!['details']),
          lastSavedAt: _dateOf(lastKeys[id], id),
        ),
    ];
  }

  DateTime? _dateOf(int? key, String id) {
    for (final line in _lines.reversed) {
      if (line['id'] == id &&
          (line['_key'] as num?)?.toInt() == key &&
          line['at'] is String) {
        return DateTime.tryParse(line['at'] as String);
      }
    }
    return null;
  }

  SessionDetails? _detailsOf(Object? json) => json is Map<String, Object?>
      ? SessionDetails.fromJson(Map<String, Object?>.from(json))
      : null;

  @override
  List<SessionEntry> readEntries(String sessionId) {
    _checkOpen();
    return [
      for (final line in _lines)
        if (line['t'] == 'entry' && line['id'] == sessionId)
          decodePersistedEntry(
              Map<String, Object?>.from(line['entry'] as Map)),
    ];
  }

  @override
  List<StoreGap> checkGaps(String sessionId) {
    _checkOpen();
    final gaps = <StoreGap>[];
    int? previousKey;
    var expectedSeq = 0;
    for (final line in _lines) {
      if (line['t'] != 'entry' || line['id'] != sessionId) continue;
      final key = (line['_key'] as num).toInt();
      final seq = (line['seq'] as num).toInt();
      if (previousKey != null && key != previousKey + 1) {
        gaps.add(StoreGap(previousKey, key));
      }
      if (seq != expectedSeq++) {
        gaps.add(StoreGap(key - 1, key));
      }
      previousKey = key;
    }
    return gaps;
  }

  @override
  SessionDetails readDetails(String sessionId) {
    _checkOpen();
    final marker = _markerOf(sessionId);
    if (marker == null) {
      throw SessionStoreException('no session $sessionId in $file');
    }
    final revision = _lastDetailsOf(sessionId);
    final source =
        revision != null ? revision['details'] : marker['details'];
    if (source is Map<String, Object?>) {
      return SessionDetails.fromJson(Map<String, Object?>.from(source));
    }
    return SessionDetails.fromJson(const {});
  }

  @override
  void close() {
    _closed = true;
  }

  /// Writes the whole log back through the WASI filesystem (the
  /// composition root's shutdown step). Close first stops mutation.
  Future<void> flush() async {
    if (_lines.isEmpty) return;
    final buffer = StringBuffer();
    for (final line in _lines) {
      buffer.writeln(jsonEncode({
        for (final entry in line.entries)
          if (entry.key != '_key') entry.key: entry.value,
      }));
    }
    final store = WasiToolFile(_preopens, _fs);
    final slash = file.lastIndexOf('/');
    if (slash > 0) {
      // The parent may not exist yet (a first run's `.tina`); WASI open
      // does not create directories, so make it before the write.
      await store.createDirectory(file.substring(0, slash), recursive: true);
    }
    await store.writeFile(file, utf8.encode(buffer.toString()));
  }
}

/// The small read/write surface the store needs over the preopens —
/// [WasiToolFileSystem] minus the tools' seam (no boundary here: the
/// store's file is the store's own).
final class WasiToolFile {
  WasiToolFile(this._preopens, this._fs);

  final WasmPreopens _preopens;
  final fs.Types _fs;

  Future<cm.Owned<fs.TypesDescriptor>> _open(
    String path, {
    bool read = false,
    bool write = false,
    bool create = false,
    bool truncate = false,
  }) async {
    final resolved = _preopens.resolve(path);
    if (resolved == null) {
      throw SessionStoreException('path outside the preopened directories: $path');
    }
    final (root, relative) = resolved;
    final opened = await _fs.methodDescriptorOpenAt(
      self: root.borrow(),
      pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(true),
      path: relative,
      openFlags: fs.TypesOpenFlags(0).withCreate(create).withTruncate(truncate),
      flags: fs.TypesDescriptorFlags(0).withRead(read).withWrite(write),
    );
    switch (opened) {
      case cm.OkResult(:final value):
        return value;
      case cm.ErrorResult(:final value):
        throw SessionStoreException('open $path failed', value.toString());
    }
  }

  Future<bool> fileExists(String path) async {
    try {
      final handle = await _open(path, read: true);
      handle.drop();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>> readFileBytes(String path) async {
    final handle = await _open(path, read: true);
    try {
      final (stream, done) =
          _fs.methodDescriptorReadViaStream(self: handle.borrow(), offset: 0);
      final chunks = <int>[];
      await for (final chunk in stream) {
        chunks.addAll(chunk);
      }
      await done;
      return chunks;
    } finally {
      handle.drop();
    }
  }

  Future<void> writeFile(String path, List<int> bytes) async {
    final handle = await _open(path, write: true, create: true, truncate: true);
    try {
      final done = _fs.methodDescriptorWriteViaStream(
        self: handle.borrow(),
        data: Stream.value(Uint8List.fromList(bytes)),
        offset: 0,
      );
      await done;
    } finally {
      handle.drop();
    }
  }

  /// Creates [path] and its missing parents (WASI open creates files,
  /// never directories).
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    final resolved = _preopens.resolve(path);
    if (resolved == null) {
      throw SessionStoreException(
          'path outside the preopened directories: $path');
    }
    final (root, relative) = resolved;
    final segments = relative.split('/').where((s) => s.isNotEmpty).toList();
    var walked = '';
    for (final segment in (recursive ? segments : segments.take(1))) {
      walked = walked.isEmpty ? segment : '$walked/$segment';
      final made = await _fs.methodDescriptorCreateDirectoryAt(
        self: root.borrow(),
        path: walked,
      );
      switch (made) {
        case cm.OkResult():
          break;
        case cm.ErrorResult(:final value):
          // An existing directory is success for a recursive walk.
          if (value.toString().toLowerCase().contains('exist')) continue;
          throw SessionStoreException('mkdir $path failed', value.toString());
      }
    }
  }
}

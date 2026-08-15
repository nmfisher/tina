/// A JSON-file-backed [Repository] for [TaskEvent] streams.
library;

import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';

/// Persists events as JSON lines, one event per line.
///
/// Writes are atomic-ish: the file is rewritten in full to a `.tmp`
/// sibling and renamed. Not safe for concurrent writers.
final class JsonFileStore implements Repository<TaskEvent> {
  final File _file;

  JsonFileStore(String path) : _file = File(path);

  @override
  Future<Result<TaskEvent, String>> fetch(String id) async {
    final events = await _readAll();
    return events.fold(
      const Err(StoreErrors.notFound),
      (best, event) => event.taskId == id ? Ok(event) : best,
    );
  }

  @override
  Future<Result<void, String>> save(TaskEvent entity) async {
    try {
      final existing = (await _readAll())
          .where((e) => e.taskId != entity.taskId || e.at > entity.at)
          .toList();
      final lines = [...existing, entity].map((e) => jsonEncode(e.toJson()));
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString('${lines.join('\n')}\n', flush: true);
      await tmp.rename(_file.path);
      return const Ok(null);
    } on FileSystemException catch (e) {
      return Err('${StoreErrors.ioFailure}: ${e.message}');
    }
  }

  @override
  Future<Result<List<TaskEvent>, String>> list() async => Ok(await _readAll());

  @override
  Future<Result<void, String>> delete(String id) async {
    try {
      final kept = (await _readAll()).where((e) => e.taskId != id).toList();
      await _file.writeAsString(
        '${kept.map((e) => jsonEncode(e.toJson())).join('\n')}\n',
        flush: true,
      );
      return const Ok(null);
    } on FileSystemException catch (e) {
      return Err('${StoreErrors.ioFailure}: ${e.message}');
    }
  }

  Future<List<TaskEvent>> _readAll() async {
    if (!await _file.exists()) return const [];
    try {
      return await _file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map(
            (line) =>
                TaskEvent.fromJson(jsonDecode(line) as Map<String, Object?>),
          )
          .toList();
    } on FormatException {
      throw const FileSystemException('corrupt event log');
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'src/input/category_catalog.dart';

/// Atomic read/modify/write with in-process serialization and a process lock.
/// The lock file is stable across atomic catalog replacements.
final class FileInputCategoryStore implements InputCategoryStore {
  FileInputCategoryStore(String path)
    : path = File(path).absolute.uri.normalizePath().toFilePath();
  final String path;
  static final _pending = <String, Future<void>>{};
  static int _sequence = 0;

  Future<T> _locked<T>(Future<T> Function() operation) async {
    final previous = _pending[path] ?? Future<void>.value();
    final finished = Completer<void>();
    _pending[path] = finished.future;
    await previous;
    RandomAccessFile? lock;
    try {
      await File(path).parent.create(recursive: true);
      lock = await File('$path.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      return await operation();
    } finally {
      try {
        await lock?.close();
      } finally {
        finished.complete();
        if (identical(_pending[path], finished.future)) _pending.remove(path);
      }
    }
  }

  Future<List<CategoryQuestion>> _read() async {
    final file = File(path);
    if (!await file.exists()) return initialCategoryQuestions();
    if (await file.length() > 4 * 1024 * 1024) {
      throw const FormatException('Category catalog too large');
    }
    final json = jsonDecode(await file.readAsString()) as Map;
    if (json['schema'] != 1)
      throw const FormatException('Unsupported category catalog');
    final questions = [
      for (final raw in json['questions'] as List)
        CategoryQuestion.fromJson(Map<String, Object?>.from(raw as Map)),
    ];
    final ids = questions.map((q) => q.id).toSet();
    if (!ids.containsAll(['intent', 'git']) || ids.length != questions.length) {
      throw const FormatException('Invalid category catalog questions');
    }
    return questions;
  }

  Future<void> _write(List<CategoryQuestion> questions) async {
    final temporary = File('$path.$pid.${_sequence++}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'schema': 1,
          'questions': [for (final q in questions) q.toJson()],
        }),
        flush: true,
      );
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<List<CategoryQuestion>> read() =>
      _locked(() async => List.unmodifiable(await _read()));
  @override
  Future<void> record(String questionId, Iterable<String> selected) {
    final ids = List<String>.of(selected);
    return _locked(() async {
      final questions = await _read();
      final index = _index(questions, questionId);
      questions[index] = questions[index].record(ids);
      await _write(questions);
    });
  }

  @override
  Future<InputCategory?> learn(String questionId, InputCategory proposed) =>
      _locked(() async {
        final questions = await _read();
        final index = _index(questions, questionId);
        final (question, category) = questions[index].learn(proposed);
        if (!identical(question, questions[index])) {
          questions[index] = question;
          await _write(questions);
        }
        return category;
      });
  int _index(List<CategoryQuestion> questions, String id) {
    final index = questions.indexWhere((q) => q.id == id);
    if (index < 0) throw const FormatException('Unknown category question');
    return index;
  }
}

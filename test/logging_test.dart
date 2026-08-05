import 'dart:io';

import 'package:tina/logging.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// The bootstrap module owns global root-logger state, so each test re-inits
/// into a fresh temp file and tears the subscription down in [tearDown].
void main() {
  late Directory tempDir;
  late File logFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tina_logging_');
    logFile = File('${tempDir.path}/tina.log');
  });

  tearDown(() async {
    await closeLogging();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('initLogging is idempotent — a second call does not double records',
      () async {
    initLogging(level: Level.ALL, logFile: logFile, mirrorToStderr: false);
    initLogging(level: Level.ALL, logFile: logFile, mirrorToStderr: false);
    Logger('tina.test').info('hello');
    await _drain();
    await closeLogging();
    final lines = await logFile.readAsLines();
    expect(lines.where((l) => l.contains('hello')), hasLength(1));
  });

  test('records are written to the log file with level and error', () async {
    initLogging(level: Level.INFO, logFile: logFile, mirrorToStderr: false);
    Logger('tina.test').warning('boom', 'theError');
    await _drain();
    await closeLogging();
    final content = await logFile.readAsString();
    expect(content, contains('[WARNING]'));
    expect(content, contains('boom'));
    expect(content, contains('theError'));
  });

  test('creates a non-existent parent directory for the log file', () async {
    final nested = File('${tempDir.path}/nested/dir/tina.log');
    initLogging(level: Level.INFO, logFile: nested, mirrorToStderr: false);
    Logger('tina.test').info('deep');
    await _drain();
    await closeLogging();
    expect(await nested.exists(), isTrue);
    expect(await nested.readAsString(), contains('deep'));
  });

  test('degrades to stderr-only when the log file cannot be opened', () async {
    // Regression guard: openWrite opens asynchronously, so an unwritable path
    // used to surface as an unhandled zone error mid-TUI — killing the process
    // without terminal teardown (raw tty left behind). A blocker FILE in the
    // parent slot makes the open fail while initLogging itself stays sync.
    final blocker = File('${tempDir.path}/blocker');
    await blocker.writeAsString('x');
    final impossible = File('${blocker.path}/tina.log');
    initLogging(level: Level.INFO, logFile: impossible, mirrorToStderr: false);
    Logger('tina.test').info('still logging');
    await _drain();
    await closeLogging();
    // No crash, no log file — the sink was dropped instead of dying.
    expect(await impossible.exists(), isFalse);
  });

  test('degrades when the parent directory cannot be created', () async {
    // createSync throws synchronously (e.g. read-only HOME): the parent dir
    // creation must be caught, not propagated. A FILE in the ancestor slot
    // makes the recursive create fail.
    final blocker = File('${tempDir.path}/blocker');
    await blocker.writeAsString('x');
    final impossible = File('${blocker.path}/missing/tina.log');
    initLogging(level: Level.INFO, logFile: impossible, mirrorToStderr: false);
    Logger('tina.test').info('still logging');
    await _drain();
    await closeLogging();
    expect(await impossible.exists(), isFalse);
  });
}

/// onRecord delivery is asynchronous, so pump the event loop before flushing so
/// the record reaches the sink buffer; [closeLogging] then flushes it to disk.
Future<void> _drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

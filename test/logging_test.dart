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
}

/// onRecord delivery is asynchronous, so pump the event loop before flushing so
/// the record reaches the sink buffer; [closeLogging] then flushes it to disk.
Future<void> _drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

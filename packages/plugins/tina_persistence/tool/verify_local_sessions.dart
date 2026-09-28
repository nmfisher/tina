/// Opt-in acceptance check. Reads private legacy files, writes only a temporary
/// SQLite database, prints counts/IDs (never conversation text), then cleans up.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_persistence/tina_persistence.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main(List<String> args) {
  if (args.length != 1)
    throw ArgumentError(
        'usage: dart run tool/verify_local_sessions.dart LEGACY_ROOT');
  final temp = Directory.systemTemp.createTempSync('tina-real-import-');
  final store = SessionStore.open('${temp.path}/import.db');
  try {
    const importer = LegacySessionImporter();
    final results = importer.importPath(args.single, store: store);
    var count = 0, messages = 0, repairs = 0;
    for (final result in results) {
      if (result.status == LegacyImportStatus.failed) {
        stdout.writeln(
            'unavailable: ${result.id ?? result.source}: ${result.error}');
        continue;
      }
      check(result.status == LegacyImportStatus.imported,
          'unexpected import status');
      final bytes = File(result.source).readAsBytesSync();
      final original = const LineSplitter()
          .convert(utf8.decode(bytes))
          .where((line) => line.trim().isNotEmpty)
          .map((line) =>
              Message.fromJson(jsonDecode(line) as Map<String, dynamic>))
          .toList();
      final expected = coalesceToolResults(original);
      if (recoverInterruptedToolCalls(expected)) repairs++;
      final entries = store.readEntries(result.id!);
      final derived = deriveSession(entries, const SessionSettings());
      check(
          jsonEncode(expected.map((m) => m.toJson()).toList()) ==
              jsonEncode(derived.messages.map((m) => m.toJson()).toList()),
          'transcript mismatch for ${result.id}');
      check(derived.pendingTurnId == null,
          'import left a replayable pending turn');
      check(
          store.checkGaps(result.id!).isEmpty, 'sequence gap for ${result.id}');
      final meta =
          store.readLog(result.id!).first.payload['legacy_import'] as Map;
      check(meta['transcript_sha256'] == sha256.convert(bytes).toString(),
          'source changed for ${result.id}');
      messages += original.length;
      count++;
    }
    check(count > 0, 'no real transcripts were verified');
    final repeated = importer.importPath(args.single, store: store);
    check(
        repeated.where((r) => r.status == LegacyImportStatus.skipped).length ==
            count,
        'repeat import was not idempotent');
    check(store.list().length == count, 'repeat import duplicated sessions');
    stdout.writeln(
        'PASS: $count conversations, $messages source messages, $repairs interrupted exchanges repaired; '
        '${results.where((r) => r.status == LegacyImportStatus.failed).length} unavailable conversations reported. '
        'Transcript/reasoning equality, closed history, sequence integrity, source hashes and idempotence verified.');
  } finally {
    store.close();
    temp.deleteSync(recursive: true);
  }
}

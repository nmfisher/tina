import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:tina_core/tina_core.dart';
import 'store.dart';

enum LegacyImportStatus { imported, skipped, ready, failed }

final class LegacyImportResult {
  const LegacyImportResult(this.source, this.status,
      {this.id,
      this.messages = 0,
      this.active = false,
      this.warnings = const [],
      this.error});
  final String source;
  final LegacyImportStatus status;
  final String? id, error;
  final int messages;
  final bool active;
  final List<String> warnings;
}

/// Read-only conversion of legacy flat files, manifests or session roots.
/// Passing no store is a dry run: no destination is created or opened.
final class LegacySessionImporter {
  const LegacySessionImporter();

  List<LegacyImportResult> importPath(String path, {SessionStore? store}) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) return _file(File(path), store);
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException('legacy source does not exist', path);
    }
    final directory = Directory(path);
    final manifest = File('${directory.path}/session.json');
    if (manifest.existsSync()) return _file(manifest, store);
    final sources = directory.listSync(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final out = <LegacyImportResult>[];
    for (final source in sources) {
      if (source is File && source.path.endsWith('.jsonl')) {
        out.addAll(_file(source, store));
      } else if (source is Directory) {
        final manifest = File('${source.path}/session.json');
        if (manifest.existsSync()) out.addAll(_file(manifest, store));
      }
    }
    if (out.isEmpty) throw FormatException('no legacy sessions found in $path');
    return out;
  }

  List<LegacyImportResult> _file(File file, SessionStore? store) {
    try {
      if (file.path.endsWith('.jsonl')) {
        final name = file.uri.pathSegments.last;
        final id = _id(name.substring(0, name.length - 6));
        return [
          _convert(file, {'id': id}, {'id': id}, null, null, store)
        ];
      }
      final bytes = file.readAsBytesSync();
      final manifest = _map(jsonDecode(utf8.decode(bytes)));
      final version = manifest['version'] ?? 1;
      if (version != 1 && version != 2)
        throw const FormatException('unsupported legacy manifest version');
      final sid = _id(manifest['id']);
      final conversations = manifest['conversations'];
      if (conversations is! List || conversations.isEmpty) {
        throw const FormatException('manifest has no conversations');
      }
      final seen = <String>{};
      for (final raw in conversations) {
        if (!seen.add(_id(_map(raw)['id'])))
          throw const FormatException('duplicate conversation ID');
      }
      if (manifest['transcriptsLocal'] != null &&
          manifest['transcriptsLocal'] is! bool) {
        throw const FormatException('transcriptsLocal must be a boolean');
      }
      final cwd = manifest['cwd'];
      if (cwd != null && cwd is! String)
        throw const FormatException('cwd must be a string');
      return [
        for (final raw in conversations)
          (() {
            final conversation = _map(raw);
            final cid = _id(conversation['id']);
            var transcript = File('${file.parent.path}/$cid.jsonl');
            if (manifest['transcriptsLocal'] == true && cwd is String) {
              final local = File('$cwd/.tina/sessions/$sid/$cid.jsonl');
              if (local.existsSync()) transcript = local;
            }
            return _convert(
                transcript, manifest, conversation, file, bytes, store);
          })()
      ];
    } on Object catch (error) {
      return [
        LegacyImportResult(file.path, LegacyImportStatus.failed,
            error: _problem(error))
      ];
    }
  }

  LegacyImportResult _convert(
      File transcript,
      Map<String, dynamic> manifest,
      Map<String, dynamic> conversation,
      File? manifestFile,
      List<int>? manifestBytes,
      SessionStore? store) {
    final id = 'legacy:${_id(manifest['id'])}:${_id(conversation['id'])}';
    final active = manifest['activeConversationId'] == conversation['id'] ||
        manifestFile == null;
    try {
      final bytes = transcript.readAsBytesSync();
      final messages = <Message>[];
      var number = 0;
      for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
        number++;
        if (line.trim().isEmpty) continue;
        try {
          final row = _map(jsonDecode(line));
          _keys(row, {'role', 'content', 'reasoning', 'synthetic'});
          for (final raw in row['content'] as List) {
            final block = _map(raw);
            _keys(
                block,
                switch (block['type']) {
                  'text' => {'type', 'text'},
                  'tool_use' => {
                      'type',
                      'id',
                      'name',
                      'input',
                      'arguments_parse_error'
                    },
                  'tool_result' => {
                      'type',
                      'tool_use_id',
                      'content',
                      'is_error'
                    },
                  _ => throw const FormatException('unsupported block'),
                });
          }
          for (final raw in row['reasoning'] as List? ?? const []) {
            _keys(_map(raw), {'text', 'complete', 'signature'});
          }
          messages.add(Message.fromJson(row));
        } on Object {
          throw FormatException(
              'invalid or unsupported message at line $number; no rows imported');
        }
      }
      final history = coalesceToolResults(messages);
      final repaired = recoverInterruptedToolCalls(history);
      final warnings = <String>[
        if (repaired)
          'Missing tool results were marked execution-unknown; no tool was executed.',
      ];
      const turnId = 'legacy-snapshot';
      final entries = <SessionEntry>[const TurnStartedEntry(turnId: turnId)];
      for (final message in history) {
        if (message.role == Role.user &&
            !message.isSynthetic &&
            message.content.isNotEmpty &&
            message.content.every((b) => b is TextBlock)) {
          entries.add(InputRecordedEntry(
              turnId: turnId,
              text: message.content
                  .cast<TextBlock>()
                  .map((b) => b.text)
                  .join('\n')));
        }
        entries.add(MessageAppendedEntry(turnId: turnId, message: message));
      }
      entries.add(TurnEndedEntry(
          turnId: turnId,
          reason:
              repaired ? TurnStopReason.cancelled : TurnStopReason.complete));
      for (final key in ['plan', 'goal']) {
        if (conversation[key] == null) continue;
        try {
          final value = _map(conversation[key]);
          if (key == 'plan') {
            Map<String, dynamic> item(Object? raw) {
              final value = _map(raw);
              return {
                ...value,
                'state': value['state'] == 'inProgress'
                    ? 'in_progress'
                    : value['state'],
                if (value['children'] != null)
                  'children': (value['children'] as List).map(item).toList()
              };
            }

            entries.add(PlanChangedEntry.fromJson({
              ...value,
              'items': (value['items'] as List).map(item).toList()
            }, '', 0));
          } else {
            final status = value['status'] == null
                ? <String, dynamic>{}
                : _map(value['status']);
            entries.add(GoalChangedEntry.fromJson(
                {'text': value['text'], ...status},
                status['at'] as String? ?? '',
                0));
          }
        } on Object {
          warnings.add(
              'Legacy $key was retained in metadata but could not be activated.');
        }
      }
      // Verify that a concurrent writer did not change either source while it
      // was being converted. Never repair/truncate a legacy source in place.
      final transcriptHash = sha256.convert(bytes).toString();
      if (sha256.convert(transcript.readAsBytesSync()).toString() !=
              transcriptHash ||
          (manifestFile != null &&
              sha256.convert(manifestFile.readAsBytesSync()) !=
                  sha256.convert(manifestBytes!))) {
        throw const FormatException(
            'source changed during import; stop the old app and retry');
      }
      final fingerprint = sha256
          .convert(utf8.encode(jsonEncode([
            'legacy-import-v1',
            manifest,
            conversation,
            transcriptHash,
          ])))
          .toString();
      final imported = store?.importSnapshot(
        id,
        fingerprint: fingerprint,
        provenance: {
          'format': 1,
          'source': transcript.absolute.path,
          'transcript_sha256': transcriptHash,
          'manifest': manifest,
          'conversation_id': conversation['id'],
          'active': active,
          'source_messages': messages.length,
          'warnings': warnings,
        },
        entries: [
          for (var i = 0; i < entries.length; i++) entries[i].withSeq(i)
        ],
        title: 'Imported ${manifest['id']}/${conversation['id']}',
      );
      return LegacyImportResult(
          transcript.path,
          imported == null
              ? LegacyImportStatus.ready
              : imported
                  ? LegacyImportStatus.imported
                  : LegacyImportStatus.skipped,
          id: id,
          messages: messages.length,
          active: active,
          warnings: warnings);
    } on Object catch (error) {
      return LegacyImportResult(transcript.path, LegacyImportStatus.failed,
          id: id, active: active, error: _problem(error));
    }
  }
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('invalid legacy session/conversation ID');
  }
  return value;
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);
void _keys(Map<String, dynamic> value, Set<String> allowed) {
  if (value.keys.any((k) => !allowed.contains(k)))
    throw const FormatException('unsupported fields');
}

String _problem(Object error) => switch (error) {
      FileSystemException() => '${error.message}: ${error.path}',
      FormatException() => error.message.toString().startsWith('Unexpected')
          ? 'invalid legacy JSON'
          : error.message.toString(),
      _ => 'conversion failed (${error.runtimeType}); source left unchanged',
    };

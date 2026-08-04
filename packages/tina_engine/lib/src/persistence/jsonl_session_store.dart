import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../llm/message.dart';
import '../platform/paths.dart';
import 'session_store.dart';

final _log = Logger('tina.persistence');

/// File-backed [SessionStore]. Each session is a directory under [root]:
///
///   `<root>/<sessionId>/session.json`              — manifest
///   `<root>/<sessionId>/<conversationId>.jsonl`    — one conversation's history
///
/// Append is O(1) and crash-safe per line; [replace] swaps atomically via a
/// tempfile + rename. Each `.jsonl` line is the same wire shape used over the
/// network, so files are inspectable with `cat | jq`.
///
/// **Migration:** older tina versions wrote a single flat
/// `<root>/<id>.jsonl` per session (one conversation = one session). Those are
/// read in place by [listSessions] and materialized into the nested layout
/// lazily — on the first [loadSession] (resume) or write — via copy-then-delete
/// so an interrupted migration leaves both old and new and can be retried.
class JsonlSessionStore implements SessionStore {
  final Directory root;
  static final _rng = Random.secure();

  JsonlSessionStore(this.root);

  /// Default location: `$HOME/.tina/sessions/` (or `%USERPROFILE%` on
  /// Windows). Falls back to the current directory if neither is set.
  factory JsonlSessionStore.defaultLocation() {
    final dir =
        p.join(tinaDirFromEnv(Platform.environment).path, 'sessions');
    return JsonlSessionStore(Directory(dir));
  }

  static const _manifestName = 'session.json';

  Directory _sessionDir(String sid) => Directory(p.join(root.path, sid));
  File _conversationFile(String sid, String cid) =>
      File(p.join(root.path, sid, '$cid.jsonl'));
  File _manifestFile(String sid) => File(p.join(root.path, sid, _manifestName));
  File _legacyFile(String sid) => File(p.join(root.path, '$sid.jsonl'));

  // -- Session / conversation creation -----------------------------------

  @override
  Future<String> createSession({
    required String providerId,
    String? baseUrl,
  }) async {
    await root.create(recursive: true);
    final id = _newId();
    await _sessionDir(id).create(recursive: true);
    await _writeManifest(SessionManifest(
      id: id,
      providerId: providerId,
      baseUrl: baseUrl,
      activeConversationId: '',
      conversations: const [],
    ));
    return id;
  }

  @override
  Future<String> createConversation(String sessionId, {String? model}) =>
      createConversationWithMeta(sessionId, ConversationMetaInput(model: model));

  @override
  Future<String> createConversationWithMeta(
      String sessionId, ConversationMetaInput input) async {
    await _ensureMaterialized(sessionId);
    final cid = _newId();
    final f = _conversationFile(sessionId, cid);
    await f.parent.create(recursive: true);
    await f.create();
    // Register the conversation in the manifest; the first one becomes active.
    final manifest = await _readManifest(sessionId);
    final conversations = [
      ...manifest.conversations,
      _metaFromInput(cid, input),
    ];
    await _writeManifest(SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      activeConversationId: manifest.activeConversationId.isEmpty
          ? cid
          : manifest.activeConversationId,
      conversations: conversations,
    ));
    return cid;
  }

  /// Build the persisted [ConversationMeta] for a newly created conversation
  /// from the capture-site [input]. The store owns the id (it just minted it).
  ConversationMeta _metaFromInput(String id, ConversationMetaInput input) =>
      ConversationMeta(
        id: id,
        model: input.model,
        baseUrl: input.baseUrl,
        providerId: input.providerId,
        label: input.label,
        kind: input.kind,
        targetName: input.targetName,
        promptOverride: input.promptOverride,
        policy: input.policy,
        parentConversationId: input.parentConversationId,
      );

  // -- Appends / replaces ------------------------------------------------

  @override
  Future<void> append(
      String sessionId, String conversationId, Message m) async {
    await _ensureMaterialized(sessionId);
    final f = _conversationFile(sessionId, conversationId);
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    await f.writeAsString(
      '${jsonEncode(m.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<void> replace(
      String sessionId, String conversationId, List<Message> messages) async {
    await _ensureMaterialized(sessionId);
    final target = _conversationFile(sessionId, conversationId);
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }
    final tmp = File('${target.path}.tmp');
    try {
      final sink = tmp.openWrite();
      try {
        for (final m in messages) {
          sink.writeln(jsonEncode(m.toJson()));
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await tmp.rename(target.path);
    } catch (_) {
      // Don't leave a half-written tempfile next to the real conversation.
      // Delete recursively so a directory at the tempfile path is removed too,
      // not just regular files. Check existence via FileSystemEntity.type —
      // File.exists() returns false for a directory at the same path, which
      // would skip cleanup of a directory tempfile.
      if (await FileSystemEntity.type(tmp.path) != FileSystemEntityType.notFound) {
        try {
          await Directory(tmp.path).delete(recursive: true);
        } on FileSystemException catch (e) {
          _log.warning('failed to remove tempfile ${tmp.path}', e);
        }
      }
      rethrow;
    }
  }

  // -- Reads -------------------------------------------------------------

  @override
  Future<List<Message>> loadConversation(
      String sessionId, String conversationId) async {
    await _ensureMaterialized(sessionId);
    final f = _conversationFile(sessionId, conversationId);
    final List<String> lines;
    try {
      lines = await f.readAsLines();
    } on PathNotFoundException {
      throw StateError('Conversation not found: $sessionId/$conversationId');
    }
    return _decodeLines(sessionId, conversationId, lines);
  }

  @override
  Future<SessionManifest> loadSession(String sessionId) async {
    await _ensureMaterialized(sessionId);
    final mf = _manifestFile(sessionId);
    try {
      final manifest = SessionManifest.fromJson(
          jsonDecode(await mf.readAsString()) as Map<String, dynamic>);
      return manifest;
    } on PathNotFoundException {
      throw StateError('Session not found: $sessionId');
    }
  }

  @override
  Future<void> setActiveConversation(
      String sessionId, String conversationId) async {
    await _ensureMaterialized(sessionId);
    final manifest = await _readManifest(sessionId);
    if (!manifest.conversations.any((c) => c.id == conversationId)) {
      throw StateError(
          'Conversation not found in session: $sessionId/$conversationId');
    }
    await _writeManifest(SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      activeConversationId: conversationId,
      conversations: manifest.conversations,
    ));
  }

  @override
  Future<List<SessionMeta>> listSessions() async {
    if (!await root.exists()) return const [];
    final out = <SessionMeta>[];
    await for (final entity in root.list()) {
      if (entity is Directory) {
        final sid = p.basename(entity.path);
        final mf = _manifestFile(sid);
        final FileStat dirStat;
        try {
          dirStat = await entity.stat();
        } on FileSystemException catch (e) {
          _log.warning('session list: skipped ${entity.path}', e);
          continue;
        }
        if (!await mf.exists()) continue; // incomplete/mid-migration
        final SessionManifest manifest;
        try {
          manifest = SessionManifest.fromJson(
              jsonDecode(await mf.readAsString()) as Map<String, dynamic>);
        } catch (e) {
          _log.warning('session list: skipped bad manifest $sid', e);
          continue;
        }
        var totalCount = 0;
        String? title;
        for (final c in manifest.conversations) {
          final (count, cTitle) = await _countAndTitle(sid, c.id);
          totalCount += count;
          if (c.id == manifest.activeConversationId) title = cTitle;
        }
        out.add(SessionMeta(
          id: sid,
          title: title ?? '(empty)',
          createdAt: dirStat.changed,
          updatedAt: await _newestConversationMtime(entity),
          messageCount: totalCount,
          conversationCount: manifest.conversations.length,
        ));
      } else if (entity is File && entity.path.endsWith('.jsonl')) {
        // Legacy flat file (pre-multi-conversation). Read in place without
        // migrating — it materializes on first resume/write.
        final sid = p.basenameWithoutExtension(entity.path);
        final FileStat stat;
        final List<String> lines;
        try {
          stat = await entity.stat();
          lines = await entity.readAsLines();
        } on FileSystemException catch (e) {
          _log.fine('session list: skipped legacy ${entity.path}', e);
          continue;
        }
        final (count, title) = _countAndTitleFromLines(lines);
        out.add(SessionMeta(
          id: sid,
          title: title ?? '(empty)',
          createdAt: stat.changed,
          updatedAt: stat.modified,
          messageCount: count,
          conversationCount: 1,
        ));
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  // -- Deletion ----------------------------------------------------------

  @override
  Future<void> deleteSession(String sessionId) async {
    final dir = _sessionDir(sessionId);
    try {
      await dir.delete(recursive: true);
    } on PathNotFoundException {
      // Idempotent by contract — maybe it was a legacy flat file.
      try {
        await _legacyFile(sessionId).delete();
      } on PathNotFoundException {
        // Already gone; not an error.
      }
    }
  }

  @override
  Future<void> deleteConversation(
      String sessionId, String conversationId) async {
    try {
      await _conversationFile(sessionId, conversationId).delete();
    } on PathNotFoundException {
      // Idempotent — file already gone.
    }
    // Drop the conversation from the manifest too, and fix up the active
    // pointer if it pointed here.
    try {
      final manifest = await _readManifest(sessionId);
      final remaining =
          manifest.conversations.where((c) => c.id != conversationId).toList();
      final active = manifest.activeConversationId == conversationId
          ? (remaining.isEmpty ? '' : remaining.first.id)
          : manifest.activeConversationId;
      await _writeManifest(SessionManifest(
        id: manifest.id,
        providerId: manifest.providerId,
        baseUrl: manifest.baseUrl,
        activeConversationId: active,
        conversations: remaining,
      ));
    } on PathNotFoundException {
      // No manifest (legacy/missing session) — nothing to update.
    }
  }

  @override
  Future<void> close() async {}

  // -- Migration ---------------------------------------------------------

  /// Ensure [sessionId] exists in the nested layout. If only a legacy flat
  /// `<sessionId>.jsonl` is present, materialize it into a directory + manifest
  /// via copy-then-delete (recoverable). No-op if already nested.
  ///
  /// Throws [StateError] if neither the nested layout nor a legacy flat file
  /// exists for [sessionId].
  Future<void> _ensureMaterialized(String sessionId) async {
    final dir = _sessionDir(sessionId);
    if (await dir.exists()) return;
    final legacy = _legacyFile(sessionId);
    if (!await legacy.exists()) {
      throw StateError('Session not found: $sessionId');
    }
    await dir.create(recursive: true);
    final cid = _newId();
    // Copy first, write the manifest, then delete the original — so a crash
    // leaves both old and new and the migration can retry.
    await legacy.copy(_conversationFile(sessionId, cid).path);
    await _writeManifest(SessionManifest(
      id: sessionId,
      // Provider is unknown for legacy sessions; default and let /resume use
      // the live provider (the persisted value is informational only).
      providerId: 'anthropic',
      baseUrl: null,
      activeConversationId: cid,
      conversations: [ConversationMeta(id: cid, model: null)],
    ));
    await legacy.delete();
  }

  // -- Internals ---------------------------------------------------------

  Future<void> _writeManifest(SessionManifest m) async {
    final f = _manifestFile(m.id);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    try {
      final sink = tmp.openWrite();
      try {
        sink.write(jsonEncode(m.toJson()));
        await sink.flush();
      } finally {
        await sink.close();
      }
      await tmp.rename(f.path);
    } catch (_) {
      // Don't leave a half-written tempfile next to the real manifest. The
      // rename is atomic, so a crash mid-write leaves the previous manifest
      // intact (readers see either the old manifest or the new one, never a
      // torn file) — but only if we clean up the tempfile here. Delete
      // recursively so a directory at the tempfile path (e.g. a stray or a
      // failed-open) is removed too, not just regular files. Check existence
      // via FileSystemEntity.type — File.exists() returns false for a directory
      // at the same path, which would skip cleanup of a directory tempfile.
      if (await FileSystemEntity.type(tmp.path) != FileSystemEntityType.notFound) {
        try {
          await Directory(tmp.path).delete(recursive: true);
        } on FileSystemException catch (e) {
          _log.warning('failed to remove tempfile ${tmp.path}', e);
        }
      }
      rethrow;
    }
  }

  Future<SessionManifest> _readManifest(String sessionId) async {
    final mf = _manifestFile(sessionId);
    return SessionManifest.fromJson(
        jsonDecode(await mf.readAsString()) as Map<String, dynamic>);
  }

  List<Message> _decodeLines(
      String sessionId, String conversationId, List<String> lines) {
    final out = <Message>[];
    var lineNo = 0;
    for (final line in lines) {
      lineNo++;
      if (line.trim().isEmpty) continue;
      try {
        out.add(Message.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (e) {
        // Skip the corrupt line rather than aborting the whole conversation —
        // a single bad line shouldn't make the rest of the history
        // unrecoverable, but the user should know data was dropped.
        _log.warning(
            '$sessionId/$conversationId: skipped corrupt line $lineNo', e);
      }
    }
    return out;
  }

  /// Derive (non-blank-line count, first-user-message title) from a
  /// conversation file. Returns (0, null) if the file can't be read.
  Future<(int, String?)> _countAndTitle(String sid, String cid) async {
    final f = _conversationFile(sid, cid);
    try {
      return _countAndTitleFromLines(await f.readAsLines());
    } on FileSystemException {
      return (0, null);
    }
  }

  /// Newest mtime across a session directory's conversation files, falling
  /// back to the directory's own mtime. Writing to a conversation file does
  /// NOT bump its parent directory's mtime, so we scan the files to keep
  /// "most-recently-updated" ordering honest.
  Future<DateTime> _newestConversationMtime(Directory dir) async {
    var newest = (await dir.stat()).modified;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.jsonl')) {
        final s = await e.stat();
        if (s.modified.isAfter(newest)) newest = s.modified;
      }
    }
    return newest;
  }

  (int, String?) _countAndTitleFromLines(List<String> lines) {
    var count = 0;
    String? title;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      count++;
      if (title == null) {
        try {
          final m = Message.fromJson(jsonDecode(line) as Map<String, dynamic>);
          if (m.role == Role.user) {
            for (final b in m.content) {
              if (b is TextBlock && b.text.trim().isNotEmpty) {
                title = _summarize(b.text);
                break;
              }
            }
          }
        } catch (e) {
          _log.fine('title parse skipped corrupt line', e);
        }
      }
    }
    return (count, title);
  }

  static String _newId() {
    final now = DateTime.now().toUtc();
    String pad(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${pad(now.month)}${pad(now.day)}'
        '-${pad(now.hour)}${pad(now.minute)}${pad(now.second)}';
    final rand = _rng.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return '$stamp-$rand';
  }

  static String _summarize(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.length <= 60 ? cleaned : '${cleaned.substring(0, 60)}…';
  }
}

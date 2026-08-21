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
///   `<root>/<sessionId>/session.json`              — manifest (always global)
///   `<root>/<sessionId>/<conversationId>.jsonl`    — legacy transcript location
///
/// For sessions created with `transcriptsLocal` (see [SessionManifest]), the
/// transcripts instead live in the project-local sidecar:
///
///   `<cwd>/.tina/sessions/<sessionId>/<conversationId>.jsonl`
///
/// The manifest and the per-session `.lock` always stay under [root] so the
/// global index (and `--continue`'s folder scoping) keeps working; only the
/// bulky transcript files travel with the project. Reads fall back to the
/// global location (e.g. the recorded `cwd` was deleted); writes fall back
/// only when the `cwd` directory no longer exists. Sessions created before
/// the split are never migrated — they keep the global layout forever.
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
    final dir = p.join(tinaDirFromEnv(Platform.environment).path, 'sessions');
    return JsonlSessionStore(Directory(dir));
  }

  static const _manifestName = 'session.json';

  Directory _sessionDir(String sid) => Directory(p.join(root.path, sid));
  File _conversationFile(String sid, String cid) =>
      File(p.join(root.path, sid, '$cid.jsonl'));
  File _manifestFile(String sid) => File(p.join(root.path, sid, _manifestName));
  File _legacyFile(String sid) => File(p.join(root.path, '$sid.jsonl'));

  /// Project-local transcript directory for a session started in [cwd], or
  /// null when the manifest carries no cwd.
  Directory? _projectTranscriptDir(String? cwd, String sid) => cwd == null
      ? null
      : Directory(p.join(cwd, '.tina', 'sessions', sid));

  /// Resolve a conversation file for WRITING: the project-local sidecar when
  /// the manifest says so and the recorded cwd still exists, else the global
  /// session directory.
  Future<File> _resolveConversationFile(
      SessionManifest manifest, String cid) async {
    if (manifest.transcriptsLocal &&
        manifest.cwd != null &&
        await Directory(manifest.cwd!).exists()) {
      return File(p.join(
          manifest.cwd!, '.tina', 'sessions', manifest.id, '$cid.jsonl'));
    }
    return _conversationFile(manifest.id, cid);
  }

  /// Resolve a conversation file for READING/DELETING: project-local first
  /// (when the manifest says so), then the global session directory.
  Future<File> _findConversationFile(
      SessionManifest manifest, String cid) async {
    final projectDir = _projectTranscriptDir(manifest.cwd, manifest.id);
    if (manifest.transcriptsLocal && projectDir != null) {
      final local = File(p.join(projectDir.path, '$cid.jsonl'));
      if (await local.exists()) return local;
    }
    return _conversationFile(manifest.id, cid);
  }

  /// [_findConversationFile] for callers that hold only a session id. A
  /// missing manifest (incomplete/mid-migration directory) reads as "no such
  /// conversation" via the global path, preserving the pre-split behavior
  /// where the failed read surfaces as StateError from the caller.
  Future<File> _findConversationFileSafe(String sid, String cid) async {
    try {
      return await _findConversationFile(await _readManifest(sid), cid);
    } on PathNotFoundException {
      return _conversationFile(sid, cid);
    }
  }

  /// The on-disk directory backing [sessionId] (where the manifest, history
  /// files, and a per-session `.lock` live). Exposed so callers can place a
  /// [SessionLock] without reaching into the private layout.
  Directory directoryFor(String sessionId) => _sessionDir(sessionId);

  // -- Session / conversation creation -----------------------------------

  @override
  Future<String> createSession({
    required String providerId,
    String? baseUrl,
    String? cwd,
    String? sessionId,
  }) async {
    await root.create(recursive: true);
    // Honor a caller pre-allocated id when its directory isn't taken (see
    // SessionStore.createSession); fall back to minting one on the rare
    // collision so creation can never fail here.
    var id = sessionId ?? _newId();
    if (sessionId != null && await _sessionDir(sessionId).exists()) {
      id = _newId();
    }
    await _sessionDir(id).create(recursive: true);
    await _writeManifest(SessionManifest(
      id: id,
      providerId: providerId,
      baseUrl: baseUrl,
      cwd: cwd,
      activeConversationId: '',
      conversations: const [],
      // New sessions keep their transcripts in the project-local sidecar
      // (`<cwd>/.tina/sessions/<id>/`). Old sessions (flag absent) never move.
      transcriptsLocal: true,
    ));
    return id;
  }

  @override
  Future<String> createConversation(String sessionId, {String? model}) =>
      createConversationWithMeta(
          sessionId, ConversationMetaInput(model: model));

  @override
  Future<String> createConversationWithMeta(
      String sessionId, ConversationMetaInput input) async {
    await _ensureMaterialized(sessionId);
    final cid = _newId();
    // Register the conversation in the manifest; the first one becomes active.
    final manifest = await _readManifest(sessionId);
    final f = await _resolveConversationFile(manifest, cid);
    await f.parent.create(recursive: true);
    await f.create();
    final conversations = [
      ...manifest.conversations,
      _metaFromInput(cid, input),
    ];
    await _writeManifest(SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      cwd: manifest.cwd,
      activeConversationId: manifest.activeConversationId.isEmpty
          ? cid
          : manifest.activeConversationId,
      conversations: conversations,
      transcriptsLocal: manifest.transcriptsLocal,
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
    final f = await _resolveConversationFile(
        await _readManifest(sessionId), conversationId);
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    // One handle for repair + write, so the two steps can't interleave with
    // another append through this path.
    final raf = await f.open(mode: FileMode.append);
    try {
      await _repairUnterminatedTail(raf);
      await raf.writeFrom(utf8.encode('${jsonEncode(m.toJson())}\n'));
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// A crash mid-append (kill -9, power loss) can leave the file without a
  /// trailing newline. Appending then would glue the new record onto the
  /// unterminated tail, and the next load drops BOTH lines (tin-g2w9). Two
  /// tail shapes need different repairs:
  ///
  /// - The tail parses as a complete record — the crash landed between the
  ///   record bytes and its newline. Terminate the line; the record is good.
  /// - The tail does not parse — a torn write. Drop it back to the last
  ///   newline; the loader has already skipped it as corrupt.
  ///
  /// On return the file ends with `\n` (or is empty) and the handle's
  /// position is the file's new length — Dart's append mode only *seeks* to
  /// the end at open, it does not force writes there, so the caller's
  /// [RandomAccessFile.writeFrom] lands exactly where this leaves it.
  Future<void> _repairUnterminatedTail(RandomAccessFile raf) async {
    final length = await raf.length();
    if (length == 0) return;
    await raf.setPosition(length - 1);
    final last = await raf.read(1);
    if (last.isEmpty) {
      await raf.setPosition(length);
      return;
    }
    if (last.first == 0x0a) {
      await raf.setPosition(length);
      return;
    }

    // Read back in chunks until the last newline is in hand. The window
    // starts small (one record's worth) and doubles, so a multi-hundred-KB
    // single message still resolves correctly.
    var windowSize = _tailWindow;
    while (true) {
      final start = length - windowSize;
      await raf.setPosition(start < 0 ? 0 : start);
      final window = await raf.read(length - (start < 0 ? 0 : start));
      final nl = window.lastIndexOf(0x0a);
      if (nl >= 0 || start <= 0) {
        final tail = nl >= 0 ? window.sublist(nl + 1) : window;
        if (_parsesAsRecord(tail)) {
          await raf.setPosition(length);
          await raf.writeByte(0x0a);
        } else {
          final keep = nl >= 0 ? (start < 0 ? 0 : start) + nl + 1 : 0;
          await raf.truncate(keep);
          await raf.setPosition(keep);
          _log.warning('dropped torn final record (${tail.length} bytes) from '
              '${raf.path} before append');
        }
        return;
      }
      windowSize *= 2;
    }
  }

  /// Whether [bytes] are a complete JSON record (best effort — enough to
  /// distinguish "record missing only its newline" from "torn write").
  bool _parsesAsRecord(List<int> bytes) {
    try {
      jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Initial backward-scan window for [_repairUnterminatedTail] (64 KiB —
  /// comfortably above any single record; grows to the file size if needed).
  static const _tailWindow = 64 * 1024;

  @override
  Future<void> replace(
      String sessionId, String conversationId, List<Message> messages) async {
    await _ensureMaterialized(sessionId);
    final target = await _resolveConversationFile(
        await _readManifest(sessionId), conversationId);
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
      if (await FileSystemEntity.type(tmp.path) !=
          FileSystemEntityType.notFound) {
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
    final f = await _findConversationFileSafe(sessionId, conversationId);
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
      cwd: manifest.cwd,
      activeConversationId: conversationId,
      conversations: manifest.conversations,
      usageTokens: manifest.usageTokens,
      transcriptsLocal: manifest.transcriptsLocal,
    ));
  }

  @override
  Future<void> updateConversationModel(String sessionId,
      String conversationId,
      {required String model, String? label}) async {
    await _ensureMaterialized(sessionId);
    final manifest = await _readManifest(sessionId);
    var found = false;
    final updated = [
      for (final c in manifest.conversations)
        () {
          if (c.id != conversationId) return c;
          found = true;
          return ConversationMeta(
            id: c.id,
            model: model,
            baseUrl: c.baseUrl,
            providerId: model.contains('/')
                ? model.substring(0, model.indexOf('/'))
                : c.providerId,
            label: label ?? c.label,
            kind: c.kind,
            targetName: c.targetName,
            promptOverride: c.promptOverride,
            policy: c.policy,
            parentConversationId: c.parentConversationId,
          );
        }(),
    ];
    if (!found) {
      throw StateError(
          'Conversation not found in session: $sessionId/$conversationId');
    }
    await _writeManifest(SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      cwd: manifest.cwd,
      activeConversationId: manifest.activeConversationId,
      conversations: updated,
      usageTokens: manifest.usageTokens,
      transcriptsLocal: manifest.transcriptsLocal,
    ));
  }

  @override
  Future<void> updateSessionUsage(String sessionId, int tokens) async {
    await _ensureMaterialized(sessionId);
    final manifest = await _readManifest(sessionId);
    await _writeManifest(SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      cwd: manifest.cwd,
      activeConversationId: manifest.activeConversationId,
      conversations: manifest.conversations,
      usageTokens: tokens < 0 ? 0 : tokens,
      transcriptsLocal: manifest.transcriptsLocal,
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
          final (count, cTitle) = await _countAndTitle(manifest, c.id);
          totalCount += count;
          if (c.id == manifest.activeConversationId) title = cTitle;
        }
        out.add(SessionMeta(
          id: sid,
          title: title ?? '(empty)',
          createdAt: dirStat.changed,
          updatedAt: await _newestConversationMtime(entity,
              projectDir: _projectTranscriptDir(manifest.cwd, sid)),
          messageCount: totalCount,
          conversationCount: manifest.conversations.length,
          cwd: manifest.cwd,
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
    // Clean up the project-local transcript dir too, when there is one.
    try {
      final manifest = await _readManifest(sessionId);
      final projectDir =
          _projectTranscriptDir(manifest.cwd, sessionId);
      if (manifest.transcriptsLocal &&
          projectDir != null &&
          await projectDir.exists()) {
        await projectDir.delete(recursive: true);
      }
    } on PathNotFoundException {
      // Manifest already gone — nothing project-local to check.
    }
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
      final manifest = await _readManifest(sessionId);
      final f = await _findConversationFile(manifest, conversationId);
      if (await f.exists()) await f.delete();
    } on PathNotFoundException {
      // Idempotent — file (or manifest) already gone.
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
        cwd: manifest.cwd,
        activeConversationId: active,
        conversations: remaining,
        usageTokens: manifest.usageTokens,
        transcriptsLocal: manifest.transcriptsLocal,
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
      if (await FileSystemEntity.type(tmp.path) !=
          FileSystemEntityType.notFound) {
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
  Future<(int, String?)> _countAndTitle(
      SessionManifest manifest, String cid) async {
    final f = await _findConversationFile(manifest, cid);
    try {
      return _countAndTitleFromLines(await f.readAsLines());
    } on FileSystemException {
      return (0, null);
    }
  }

  /// Newest mtime across a session directory's conversation files, falling
  /// back to the directory's own mtime. Writing to a conversation file does
  /// NOT bump its parent directory's mtime, so we scan the files to keep
  /// "most-recently-updated" ordering honest. For project-local sessions the
  /// transcripts live in [projectDir] instead, so both are scanned.
  Future<DateTime> _newestConversationMtime(Directory dir,
      {Directory? projectDir}) async {
    var newest = (await dir.stat()).modified;
    Future<void> scan(Directory d) async {
      await for (final e in d.list()) {
        if (e is File && e.path.endsWith('.jsonl')) {
          final s = await e.stat();
          if (s.modified.isAfter(newest)) newest = s.modified;
        }
      }
    }

    await scan(dir);
    if (projectDir != null && await projectDir.exists()) await scan(projectDir);
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

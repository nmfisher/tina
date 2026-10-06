import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';

import 'context_file_mirror.dart';
import 'working_context.dart';

/// An invalid edit, as opposed to a failed durable write.
final class ContextEditRejected extends StateError {
  ContextEditRejected(super.message);
}

final class ContextPersistenceFailure extends StateError {
  ContextPersistenceFailure(this.cause)
      : super('Working-context persistence failed');
  final Object cause;
}

/// Explicitly opt-in. A file mirror is enabled only with an explicit path.
final class ContextPlugin extends AgentPlugin {
  ContextPlugin({File? mirrorFile})
      : onMirrorReady = null,
        _sessionMirror = false,
        _mirror = mirrorFile == null ? null : ContextFileMirror(mirrorFile);

  /// Allocate a private editing surface for each host session. Persistence
  /// remains in the session log; this temporary file is regenerated on resume.
  ContextPlugin.sessionMirror({this.onMirrorReady}) : _sessionMirror = true;

  final void Function(File)? onMirrorReady;
  final bool _sessionMirror;
  Directory? _ownedDirectory;
  ContextFileMirror? _mirror;
  File? get mirrorFile => _mirror?.file;
  ContextEditReceipt? get lastReceipt => _mirror?.lastReceipt;
  ContextEditReceipt? get lastEditReceipt => _mirror?.lastEditReceipt;
  String get fileStatus => _mirror?.fileStatus ?? 'No file mirror';

  /// Latest eligible accepted replacement, replayed from the original log.
  /// This also works after resume and excludes edits from abandoned turns.
  ({WorkingContext before, WorkingContextSnapshot after})? get latestChange {
    final loop = _mounted;
    final completed = {
      for (final e in loop.log.whereType<TurnEndedEntry>()) e.turnId
    };
    final active = loop.inTurn ? loop.derive().pendingTurnId : null;
    for (final entry in loop.log.reversed) {
      if (entry is ContextClearedEntry) break;
      if (entry is! PluginStateEntry ||
          entry.pluginId != id ||
          entry.stateKey != workingContextKey) continue;
      final snapshot = WorkingContextSnapshot.fromEntry(entry);
      if (snapshot.originTurnId != null &&
          snapshot.originTurnId != active &&
          !completed.contains(snapshot.originTurnId)) continue;
      return (
        before: deriveWorkingContext(loop.log.sublist(0, entry.seq),
            includePendingTurn: true),
        after: snapshot,
      );
    }
    return null;
  }

  @override
  String get id => contextPluginId;

  @override
  int get order => 800;

  AgentLoop? _loop;
  void Function(PluginStateEntry)? _write;
  bool _writeFailed = false;

  @override
  SessionSeed? openSession(PluginSession session) {
    if (_sessionMirror) {
      if (_ownedDirectory != null)
        throw StateError('Context session already open');
      _ownedDirectory = Directory.systemTemp.createTempSync('tina-context-');
      _mirror = ContextFileMirror(File('${_ownedDirectory!.path}/live.json'));
    }
    return null;
  }

  @override
  void mountOn(AgentLoop loop) {
    if (_loop != null) throw StateError('Context plugin already mounted');
    deriveWorkingContext(loop.log); // Validate restored state before use.
    _loop = loop;
    _write = loop.stateWriter(id);
    _writeFailed = false;
    _mirror?.initialize(workingContext);
    if (_mirror case final ContextFileMirror mirror) {
      onMirrorReady?.call(mirror.file);
    }
  }

  AgentLoop get _mounted =>
      _loop ?? (throw StateError('Context plugin is not mounted'));

  WorkingContext get workingContext {
    if (_writeFailed) throw StateError('Working-context persistence failed');
    final loop = _mounted;
    return deriveWorkingContext(loop.log, includePendingTurn: loop.inTurn);
  }

  /// Both counters are required: messages may have arrived since an editor
  /// read the context even if no other edit has incremented its revision.
  WorkingContext replaceWorkingContext({
    required int expectedRevision,
    required int expectedThroughSeq,
    required List<Message> messages,
  }) {
    final loop = _mounted;
    final current = workingContext;
    if (current.revision != expectedRevision ||
        current.throughSeq != expectedThroughSeq) {
      throw ContextEditRejected('Stale working-context edit');
    }
    final replacement = freezeMessages(messages);
    validateContextMessages(replacement);
    // Provider signatures are opaque. Retain the exact signed block or drop
    // it; callers cannot fabricate or rewrite signed reasoning.
    final signed = <String, ReasoningBlock>{
      for (final m in current.messages)
        for (final r in m.reasoning)
          if (r.signature != null) r.signature!: r,
    };
    for (final m in replacement) {
      for (final r in m.reasoning) {
        if (r.signature == null) continue;
        final original = signed[r.signature];
        if (original == null ||
            original.text != r.text ||
            original.complete != r.complete) {
          throw const FormatException('Signed reasoning must remain intact');
        }
      }
    }
    if (loop.inTurn) {
      final active = loop.derive().pendingTurnId;
      final turnMessages = [
        for (final e in loop.log.whereType<MessageAppendedEntry>())
          if (e.turnId == active) e.message,
      ];
      // The accepted user request stays intact, but settled tool exchanges
      // within this same turn can be rewritten or evicted. Outstanding calls
      // must settle before any replacement can be accepted.
      if (turnMessages.isNotEmpty &&
          !replacement.any((m) => sameMessages([m], [turnMessages.first]))) {
        throw ContextEditRejected(
            'The current user request must remain intact');
      }
      final pending = <String>{};
      for (final m in turnMessages) {
        pending.addAll(m.content.whereType<ToolUseBlock>().map((b) => b.id));
        pending.removeAll(
            m.content.whereType<ToolResultBlock>().map((b) => b.toolUseId));
      }
      if (pending.isNotEmpty) {
        throw ContextEditRejected('The executing tool batch must settle first');
      }
    }
    final snapshot = WorkingContextSnapshot(
      revision: current.revision + 1,
      throughSeq: current.throughSeq,
      originTurnId: loop.inTurn ? loop.derive().pendingTurnId : null,
      messages: replacement,
    );
    try {
      _write!(snapshot.toEntry());
    } catch (error) {
      // The loop may have appended in memory before a persistence listener
      // threw. Never use that unconfirmed edit in another provider request.
      _writeFailed = true;
      throw ContextPersistenceFailure(error);
    }
    return workingContext;
  }

  @override
  void onPrompt(TurnContext c) {
    final mirror = _mirror;
    if (mirror == null) return;
    c.promptSections.add('Your editable working context is at '
        '${mirror.file.path}. Edit only its messages array using file tools. '
        'Keep schema_version, revision, and through_seq unchanged. '
        'Edits are validated and applied before the next model call. '
        'Keep the current user request intact and keep retained tool calls '
        'paired with their results.');
  }

  @override
  void beforeModelCall(TurnContext c) {
    final current = workingContext;
    final mirror = _mirror;
    final updated = mirror == null
        ? current
        : mirror.synchronize(current, (messages) {
            try {
              return replaceWorkingContext(
                  expectedRevision: current.revision,
                  expectedThroughSeq: current.throughSeq,
                  messages: messages);
            } on ContextEditRejected catch (error) {
              throw FormatException(error.message);
            }
          });
    c.messages = List.of(updated.messages);
    final receipt = mirror?.lastReceipt;
    if (receipt != null && receipt.status != ContextEditStatus.unchanged) {
      c.messages.add(Message(
          role: Role.user,
          isSynthetic: true,
          content: [TextBlock(receipt.message)]));
    }
  }

  @override
  void closeSession() {
    _loop = null;
    _write = null;
    final directory = _ownedDirectory;
    _ownedDirectory = null;
    if (directory != null) {
      _mirror = null;
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }
}

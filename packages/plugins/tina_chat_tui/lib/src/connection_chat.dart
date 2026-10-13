import 'dart:async';
import 'dart:convert';
import 'package:tina_chat/observation.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

/// Chat's existing presentation contract, backed exclusively by session data.
/// Each listener owns an attachment; releasing it never closes the connection.
final class ConnectionChatObservation
    implements ChatObservation, SessionObservation {
  ConnectionChatObservation(this._connection);
  final SessionConnection _connection;
  SessionSnapshot? _current;
  Map<String, Object?> _descriptions = const {};
  Map get _chat => _current?.features['tina/chat-tui'] as Map? ?? const {};
  @override
  SessionObservation get events => this;
  @override
  bool get running => _current?.status.busy ?? _connection.status.busy;
  @override
  String get model =>
      _chat['model'] as String? ??
      _current?.status.model ??
      _connection.status.model;
  @override
  String? get sessionId => _current?.status.id ?? _connection.status.id;
  @override
  int get tokenCap => _chat['token_cap'] as int? ?? 0;
  @override
  int? get sessionTokens => _chat['session_tokens'] as int?;
  @override
  int get sessionEstimatedTokens => _chat['estimated_tokens'] as int? ?? 0;
  @override
  bool get showSessionId => _chat['show_session_id'] as bool? ?? true;
  @override
  bool get terminalAlertsEnabled =>
      _chat['terminal_alerts_enabled'] as bool? ?? true;
  @override
  Map<String, Object?> get snapshot => Map<String, Object?>.unmodifiable(_chat);
  @override
  ToolDescription? describe(ToolUse call) =>
      ToolDescription.fromJson(_descriptions[call.id]);
  @override
  void Function() listen(void Function(SessionObservationEvent) listener) =>
      _ChatSubscription(this, listener: listener).start();
  @override
  void Function() listenChanges(void Function() listener) =>
      _ChatSubscription(this, changed: listener).start();
}

final class _ChatSubscription {
  _ChatSubscription(this.owner, {this.listener, this.changed});
  final ConnectionChatObservation owner;
  final void Function(SessionObservationEvent)? listener;
  final void Function()? changed;
  late final SessionAttachment attachment;
  var closed = false;
  var afterSeq = -1;
  var unavailable = false, truncated = false;
  List<Map> preview = const [];
  final calls = <String, ToolUse>{};
  final tools = <String, Map>{};

  void Function() start() {
    attachment = owner._connection.attach();
    try {
      apply(attachment.initial, replay: true);
    } catch (_) {
      close();
      rethrow;
    }
    unawaited(observe());
    return close;
  }

  void close() {
    if (closed) return;
    closed = true;
    attachment.close();
    calls.clear();
    tools.clear();
    preview = const [];
  }

  void emit(SessionObservationEvent event) {
    if (!closed) listener?.call(event);
  }

  Future<void> observe() async {
    try {
      while (!closed) {
        final update = await attachment.next();
        if (closed || update == null) return;
        // Replacement snapshots recover coalesced updates by paging every
        // committed entry since our cursor; transient previews are not appended.
        apply(update.snapshot);
        if (update.snapshot.status.closed) close();
      }
    } catch (_) {
      // Failure of this renderer cannot stop the session or another listener.
      close();
    }
  }

  void apply(SessionSnapshot snapshot, {bool replay = false}) {
    if (owner._current == null ||
        snapshot.cursor.revision >= owner._current!.cursor.revision) {
      owner._current = snapshot;
    }
    if (listener == null) {
      if (!replay) changed?.call();
      return;
    }
    final feature = snapshot.features['tina/chat-tui'] as Map?;
    final missing = feature == null || snapshot.historyPublicationFailed;
    if (missing && !unavailable && !replay) reset();
    history(snapshot, replay: replay || missing);
    if (closed) return;
    if (missing) {
      if (!unavailable)
        emit(const ObservedModel(SawNotice(
            'Live chat preview unavailable; displaying confirmed history.')));
      unavailable = true;
      return;
    }
    unavailable = false;
    final next = (feature['preview'] as List).cast<Map>();
    var delta = _previewDelta(preview, next);
    if (delta == null) {
      // A corrected/replaced preview cannot be treated as another token. A
      // fresh projection is rare; normal token updates preserve folds/scroll.
      reset();
      history(snapshot, replay: true);
      delta = next;
    }
    for (final event in delta) emit(ObservedModel(_decodePreview(event)));
    preview = next;
    if (feature['preview_truncated'] == true && !truncated) {
      emit(const ObservedModel(SawNotice(
          'Earlier live preview omitted; the completed response will reconcile it.')));
    }
    truncated = feature['preview_truncated'] == true;
    activity(snapshot);
  }

  void reset() {
    afterSeq = -1;
    preview = const [];
    tools.clear();
    calls.clear();
    truncated = false;
    emit(const ObservedReset());
  }

  void history(SessionSnapshot snapshot, {required bool replay}) {
    while (!closed && afterSeq < snapshot.throughSeq) {
      final page = attachment.history(snapshot: snapshot, afterSeq: afterSeq);
      if (page.nextAfterSeq <= afterSeq)
        throw StateError('History cursor did not advance');
      for (final data in page.entries) {
        if (closed) return;
        final entry = SessionEntry.fromJson(Map<String, dynamic>.from(data));
        final metadata =
            (data['features'] as Map?)?['tina/chat-tui'] as Map? ?? const {};
        owner._descriptions = Map<String, Object?>.from(
            metadata['tool_descriptions'] as Map? ?? const {});
        if (entry is MessageAppendedEntry) {
          for (final block in entry.message.content) {
            if (block is ToolUseBlock) {
              calls[block.id] = ToolUse.fromBlock(block);
              tools.remove(block.id);
            } else if (block is ToolResultBlock) {
              final call = calls.remove(block.toolUseId);
              final result =
                  (metadata['tool_results'] as Map?)?[block.toolUseId] as Map?;
              if (call != null)
                emit(ObservedActivity(
                    ToolFinished(
                        call,
                        ToolResult(block.content,
                            isError: block.isError,
                            images: block.images,
                            elapsed: result?['elapsed_us'] == null
                                ? null
                                : Duration(
                                    microseconds:
                                        result!['elapsed_us'] as int))),
                    DateTime.tryParse(entry.at) ??
                        DateTime.fromMillisecondsSinceEpoch(0)));
              tools.remove(block.toolUseId);
            }
          }
          if (entry.message.role == Role.assistant) preview = const [];
        } else if (entry is TurnStartedEntry ||
            entry is TurnEndedEntry ||
            entry is ContextClearedEntry) {
          preview = const [];
          truncated = false;
          calls.clear();
          tools.clear();
        }
        emit(
            ObservedEntry(entry, replay ? LogEvent.replay : LogEvent.appended));
        afterSeq = entry.seq;
      }
    }
  }

  void activity(SessionSnapshot snapshot) {
    tools.removeWhere((id, _) => !snapshot.activeTools.containsKey(id));
    for (final entry in snapshot.activeTools.entries) {
      final data = entry.value as Map;
      final call = calls[entry.key] ??
          ToolUse(
              id: entry.key,
              name: data['name'] as String,
              input: Map<String, dynamic>.from(data['input'] as Map));
      final previous = tools[entry.key];
      final at = DateTime.fromMillisecondsSinceEpoch(0);
      if (previous == null) emit(ObservedActivity(ToolStarted(call), at));
      if (data['status'] case final String status
          when status != previous?['status']) {
        emit(ObservedActivity(ToolProgress(call, status), at));
      }
      final output = data['output'] as String? ?? '';
      final old = previous?['output'] as String? ?? '';
      if (output.startsWith(old) && output.length > old.length) {
        emit(ObservedActivity(
            ToolOutput(call, output.substring(old.length)), at));
      }
      tools[entry.key] = data;
    }
  }
}

List<Map>? _previewDelta(List<Map> previous, List<Map> next) {
  final delta = <Map>[];
  if (next.length < previous.length) return null;
  for (var i = 0; i < previous.length; i++) {
    final old = previous[i], current = next[i];
    if (jsonEncode(old) == jsonEncode(current)) continue;
    final kind = old['kind'];
    if (i != previous.length - 1 ||
        (kind != 'text' && kind != 'thinking') ||
        current['kind'] != kind ||
        old['starts_block'] != current['starts_block'] ||
        !(current['text'] as String).startsWith(old['text'] as String))
      return null;
    delta.add({
      ...current,
      'text':
          (current['text'] as String).substring((old['text'] as String).length),
      if (kind == 'thinking') 'starts_block': false
    });
  }
  delta.addAll(next.skip(previous.length));
  return delta;
}

WatchEvent _decodePreview(Map data) => switch (data['kind']) {
      'text' => SawText(data['text'] as String),
      'thinking' => SawThinking(data['text'] as String,
          startsBlock: data['starts_block'] == true),
      'thinking_end' => SawThinkingEnd(complete: data['complete'] != false),
      'notice' => SawNotice(data['text'] as String),
      _ => throw FormatException('Unknown chat preview kind'),
    };

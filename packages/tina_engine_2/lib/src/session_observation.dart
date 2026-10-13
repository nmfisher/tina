import 'dart:async';
import 'package:tina_core/tina_core.dart';
import 'loop.dart';
import 'tee_provider.dart';
import 'tool_execution.dart';

sealed class SessionObservationEvent {
  const SessionObservationEvent();
}

/// A bounded live subscriber fell behind. Clear its projection; a fresh replay
/// follows in this delivery. Durable history remains in the engine log.
final class ObservedReset extends SessionObservationEvent {
  const ObservedReset();
}

final class ObservedEntry extends SessionObservationEvent {
  const ObservedEntry(this.entry, this.event);
  final SessionEntry entry;
  final LogEvent event;
}

final class ObservedActivity extends SessionObservationEvent {
  const ObservedActivity(this.activity, this.at);
  final ToolActivity activity;
  final DateTime at;
}

final class ObservedModel extends SessionObservationEvent {
  const ObservedModel(this.event);
  final WatchEvent event;
}

/// Read-only session observations. A subscriber receives committed history,
/// then retained current-call activity/deltas, then live events. It receives
/// neither a loop nor an executor, and owns only its own subscription.
abstract interface class SessionObservation {
  bool get running;
  String? get model;
  ToolDescription? describe(ToolUse call);
  Map<String, Object?> get snapshot;
  void Function() listenChanges(void Function() listener);
  void Function() listen(void Function(SessionObservationEvent) listener);
}

final class _LocalSessionObservation implements SessionObservation {
  _LocalSessionObservation(this._source);
  final SessionObservationSource _source;
  bool get running => _source._loop?.inTurn ?? false;
  String? get model => _source._loop?.provider.model;
  ToolDescription? describe(ToolUse call) => _source._describe(call);
  Map<String, Object?> get snapshot => _source._snapshotState();
  void Function() listenChanges(void Function() listener) =>
      _source._listenChanges(listener);
  void Function() listen(void Function(SessionObservationEvent) listener) =>
      _source._listen(listener);
}

/// Owned by a runtime feature, independent of any attached presentation.
/// Retains incomplete calls and bounded optional timing metadata; committed
/// history stays in the log.
final class SessionObservationSource implements WatchObserver {
  late final SessionObservation observation = _LocalSessionObservation(this);
  AgentLoop? _loop;
  int? _handle;
  StreamSubscription<ToolActivity>? _activity;
  final _listeners = <Object, _ObservationListener>{};
  final _stateListeners = <Object, void Function()>{};
  final _tail = <SessionObservationEvent>[];
  final _snapshots = Expando<SessionEntry>();
  final _calls = Expando<ToolUse>();
  final _finishedMetadata = <String, Map<String, Object?>>{};
  final _historyMetadata = <int, Map<String, Object?>>{};
  int _retainedCharacters = 0;
  static const _retentionLimit = 262144;
  static const _eventLimit = 4096;
  bool _previewTruncated = false;
  bool _closed = false;
  bool _scheduled = false;

  Map<String, Object?> _snapshotState() => Map.unmodifiable({
        'model': observation.model,
        'running': observation.running,
        'preview_truncated': _previewTruncated,
        'preview': List.unmodifiable([
          for (final event in _compactPreview(_tail))
            if (event case ObservedModel(:final event))
              switch (event) {
                SawText(:final text) => Map<String, Object?>.unmodifiable(
                    {'kind': 'text', 'text': text}),
                SawThinking(:final text, :final startsBlock) =>
                  Map<String, Object?>.unmodifiable({
                    'kind': 'thinking',
                    'text': text,
                    'starts_block': startsBlock
                  }),
                SawThinkingEnd(:final complete) =>
                  Map<String, Object?>.unmodifiable({
                    'kind': 'thinking_end',
                    'complete': complete,
                  }),
                SawNotice(:final text) => Map<String, Object?>.unmodifiable(
                    {'kind': 'notice', 'text': text}),
                _ => const <String, Object?>{},
              },
        ]),
      });

  /// Optional presentation metadata. Committed content remains in the log;
  /// only recent execution timing is retained here, bounded independently.
  Map<String, Object?> historyMetadata(SessionEntry entry) {
    final descriptions = <String, Object?>{};
    if (entry is MessageAppendedEntry) {
      for (final block in entry.message.content.whereType<ToolUseBlock>()) {
        try {
          final description = _describe(ToolUse.fromBlock(block));
          if (description != null)
            descriptions[block.id] = description.toJson();
        } catch (_) {/* A description cannot hide committed history. */}
      }
    }
    return {
      if (descriptions.isNotEmpty) 'tool_descriptions': descriptions,
      ...?_historyMetadata[entry.seq],
    };
  }

  void Function() _listenChanges(void Function() listener) {
    if (_closed) throw StateError('Observation is closed');
    final owner = Object();
    _stateListeners[owner] = listener;
    return () => _stateListeners.remove(owner);
  }

  void mountOn(AgentLoop loop) {
    if (_loop != null || _closed)
      throw StateError('Observation already mounted');
    _loop = loop;
    _handle = loop.subscribe((entry, event) {
      if (entry is TurnStartedEntry ||
          entry is TurnEndedEntry ||
          entry is ContextClearedEntry) {
        _tail.clear();
        _retainedCharacters = 0;
        _previewTruncated = false;
        _finishedMetadata.clear();
      } else if (entry is MessageAppendedEntry) {
        if (entry.message.role == Role.assistant) {
          _tail.removeWhere((e) => e is ObservedModel);
        }
        final completed = entry.message.content
            .whereType<ToolResultBlock>()
            .map((block) => block.toolUseId)
            .toSet();
        final metadata = <String, Object?>{};
        for (final id in completed) {
          if (_finishedMetadata.remove(id) case final value?)
            metadata[id] = value;
        }
        if (metadata.isNotEmpty) {
          _historyMetadata[entry.seq] = {'tool_results': metadata};
          if (_historyMetadata.length > 128)
            _historyMetadata.remove(_historyMetadata.keys.first);
        }
        _tail.removeWhere((e) =>
            e is ObservedActivity && completed.contains(e.activity.call.id));
        _retainedCharacters = _tail.fold(0, (sum, event) => sum + _size(event));
        if (_tail.isEmpty) _previewTruncated = false;
      }
      _publish(ObservedEntry(_snapshot(entry), event));
    });
    _activity = loop.toolActivity.listen((event) {
      final call = event.call;
      final frozenCall = _calls[call] ??= ToolUse(
          id: call.id,
          name: call.name,
          input: _freezeMap(call.input),
          argumentsParseError: call.argumentsParseError);
      final copy = _freezeActivity(event, frozenCall);
      if (event is ToolFinished) {
        _finishedMetadata[call.id] = {
          if (event.result.elapsed case final elapsed?)
            'elapsed_us': elapsed.inMicroseconds,
        };
      }
      final observed = ObservedActivity(copy, DateTime.now());
      if (event is ToolOutput) {
        _retain(observed);
      } else {
        // Repeated progress replaces its previous state, bounding idle chatter.
        if (event is ToolProgress) {
          _tail.removeWhere((e) =>
              e is ObservedActivity &&
              e.activity is ToolProgress &&
              e.activity.call.id == event.call.id);
        }
        _tail.add(observed);
      }
      _publish(observed);
    });
  }

  @override
  void watch(WatchEvent event) {
    if (_closed) return;
    // Completion/tool sightings carry no UI state; authoritative entries and
    // tool activity provide those. Retain only incomplete text/reasoning.
    if (event is! SawText &&
        event is! SawThinking &&
        event is! SawThinkingEnd &&
        event is! SawNotice) return;
    final size = switch (event) {
      SawText(:final text) ||
      SawThinking(:final text) ||
      SawNotice(:final text) =>
        text.length,
      _ => 0,
    };
    final observed = ObservedModel(event);
    if (size > 0 || event is SawThinkingEnd) _retain(observed);
    _publish(observed);
  }

  int _size(SessionObservationEvent event) => switch (event) {
        ObservedActivity(activity: ToolOutput(:final text)) => text.length,
        ObservedModel(event: SawText(:final text)) ||
        ObservedModel(event: SawThinking(:final text)) ||
        ObservedModel(event: SawNotice(:final text)) =>
          text.length,
        _ => 0,
      };
  void _retain(SessionObservationEvent event) {
    final size = _size(event);
    if (_tail.length >= _eventLimit ||
        _retainedCharacters + size > _retentionLimit) {
      _previewTruncated = true;
      return;
    }
    _tail.add(event);
    _retainedCharacters += size;
  }

  SessionEntry _snapshot(SessionEntry entry) =>
      _snapshots[entry] ??= switch (entry) {
        MessageAppendedEntry() => MessageAppendedEntry(
            turnId: entry.turnId,
            seq: entry.seq,
            at: entry.at,
            message: _freezeMessage(entry.message)),
        TurnEndedEntry() => TurnEndedEntry(
            turnId: entry.turnId,
            seq: entry.seq,
            at: entry.at,
            usage: entry.usage,
            reason: entry.reason,
            stop: entry.stop == null ? null : _freezeMap(entry.stop!)),
        _ => SessionEntry.fromJson(entry.toJson()),
      };

  ToolDescription? _describe(ToolUse call) {
    final value =
        _loop?.toolSchema(call.name)?.describe?.call(_freezeMap(call.input));
    return value == null
        ? null
        : ToolDescription(
            title: value.title,
            target: value.target,
            fields: Map.unmodifiable(value.fields));
  }

  void Function() _listen(void Function(SessionObservationEvent) listener) {
    if (_closed) throw StateError('Observation is closed');
    if (_loop?.publishing == true) {
      throw StateError('Cannot attach during synchronous publication');
    }
    final owner = Object();
    final subscription = _ObservationListener(listener);
    _listeners[owner] = subscription;
    try {
      _replay(subscription);
    } catch (_) {
      _listeners.remove(owner);
      rethrow;
    }
    return () => _listeners.remove(owner);
  }

  void _replay(_ObservationListener subscription) {
    final loop = _loop;
    // Capture all replay inputs before invoking a re-entrant client callback.
    final through = loop?.publishedSeq ?? -1;
    final tail = _compactPreview(_tail);
    final truncated = _previewTruncated;
    subscription.pending.clear();
    subscription.characters = 0;
    subscription.resync = false;
    for (var after = -1; after < through;) {
      final page = loop!
          .publishedEntries(afterSeq: after, throughSeq: through, limit: 128);
      for (final entry in page)
        subscription.listener(ObservedEntry(_snapshot(entry), LogEvent.replay));
      after += page.length;
    }
    for (final event in tail) subscription.listener(event);
    if (truncated)
      subscription.listener(const ObservedModel(SawNotice(
          'Earlier live preview omitted; the completed response will reconcile it.')));
  }

  void _publish(SessionObservationEvent event) {
    for (final subscription in _listeners.values) {
      if (subscription.resync) continue;
      final size = _size(event);
      if (subscription.pending.length >= _eventLimit ||
          subscription.characters + size > _retentionLimit) {
        subscription.pending.clear();
        subscription.characters = 0;
        subscription.resync = true;
      } else {
        subscription.pending.add(event);
        subscription.characters += size;
      }
    }
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_deliver);
  }

  void _deliver() {
    _scheduled = false;
    if (_closed) return;
    for (final entry in _stateListeners.entries.toList()) {
      if (!_stateListeners.containsKey(entry.key)) continue;
      try {
        entry.value();
      } catch (_) {
        _stateListeners.remove(entry.key);
      }
    }
    for (final item in _listeners.entries.toList()) {
      if (!_listeners.containsKey(item.key)) continue;
      try {
        final subscription = item.value;
        if (subscription.resync) {
          subscription.listener(const ObservedReset());
          if (_listeners.containsKey(item.key)) _replay(subscription);
        } else {
          final events = subscription.pending.toList();
          subscription.pending.clear();
          subscription.characters = 0;
          for (final event in events) {
            if (!_listeners.containsKey(item.key)) break;
            if (event is ObservedEntry &&
                event.entry.seq > (_loop?.publishedSeq ?? -1)) continue;
            subscription.listener(event);
          }
        }
      } catch (_) {
        // An optional presentation failure must not stop a turn or a sibling.
        _listeners.remove(item.key);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_handle case final handle?) _loop?.unsubscribe(handle);
    _handle = null;
    unawaited(_activity?.cancel());
    _activity = null;
    _loop = null;
    _tail.clear();
    _listeners.clear();
    _stateListeners.clear();
    _finishedMetadata.clear();
    _historyMetadata.clear();
  }
}

final class _ObservationListener {
  _ObservationListener(this.listener);
  final void Function(SessionObservationEvent) listener;
  final pending = <SessionObservationEvent>[];
  int characters = 0;
  bool resync = false;
}

/// Replaying thousands of tiny tokens must not cause thousands of redraws.
/// Preserve block boundaries while delivering each adjacent text run once.
List<SessionObservationEvent> _compactPreview(
    List<SessionObservationEvent> events) {
  final result = <SessionObservationEvent>[];
  StringBuffer? text;
  bool? thinking;
  var startsBlock = false;
  void flush() {
    if (text == null) return;
    result.add(ObservedModel(thinking!
        ? SawThinking(text.toString(), startsBlock: startsBlock)
        : SawText(text.toString())));
    text = null;
  }

  for (final event in events) {
    if (event case ObservedModel(event: SawText(text: final chunk))) {
      if (thinking == true) flush();
      thinking = false;
      (text ??= StringBuffer()).write(chunk);
    } else if (event
        case ObservedModel(
          event: SawThinking(text: final chunk, startsBlock: final starts)
        )) {
      if (thinking == false || starts) flush();
      if (text == null) startsBlock = starts;
      thinking = true;
      (text ??= StringBuffer()).write(chunk);
    } else {
      flush();
      result.add(event);
    }
  }
  flush();
  return result;
}

Map<String, dynamic> _freezeMap(Map<String, dynamic> input) =>
    Map.unmodifiable({
      for (final item in input.entries) item.key: _freezeValue(item.value),
    });
Object? _freezeValue(Object? value) => switch (value) {
      Map value => _freezeMap(Map<String, dynamic>.from(value)),
      List value => List.unmodifiable(value.map(_freezeValue)),
      _ => value,
    };
Message _freezeMessage(Message message) => Message(
    role: message.role,
    isSynthetic: message.isSynthetic,
    reasoning: List.unmodifiable(message.reasoning),
    content: List.unmodifiable(message.content.map((block) => switch (block) {
          ToolUseBlock() => ToolUseBlock(
              id: block.id,
              name: block.name,
              input: _freezeMap(block.input),
              argumentsParseError: block.argumentsParseError),
          ToolResultBlock() => ToolResultBlock(
              toolUseId: block.toolUseId,
              content: block.content,
              isError: block.isError,
              images: List.unmodifiable(block.images)),
          _ => block,
        })));
ToolActivity _freezeActivity(ToolActivity event, ToolUse copy) {
  return switch (event) {
    ToolStarted() => ToolStarted(copy),
    ToolOutput(:final text, :final isError) =>
      ToolOutput(copy, text, isError: isError),
    ToolProgress(:final status) => ToolProgress(copy, status),
    ToolFinished(:final result) => ToolFinished(
        copy,
        ToolResult(result.content,
            isError: result.isError,
            elapsed: result.elapsed,
            timedOut: result.timedOut,
            emptyOutput: result.emptyOutput,
            images: List.unmodifiable(result.images))),
  };
}

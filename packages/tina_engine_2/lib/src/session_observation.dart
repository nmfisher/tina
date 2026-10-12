import 'dart:async';
import 'package:tina_core/tina_core.dart';
import 'loop.dart';
import 'tee_provider.dart';
import 'tool_execution.dart';

sealed class SessionObservationEvent {
  const SessionObservationEvent();
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
final class SessionObservation {
  SessionObservation._(this._source);
  final SessionObservationSource _source;
  bool get running => _source._loop?.inTurn ?? false;
  String? get model => _source._loop?.provider.model;
  ToolDescription? describe(ToolUse call) => _source._describe(call);
  void Function() listen(void Function(SessionObservationEvent) listener) =>
      _source._listen(listener);
}

/// Owned by a runtime feature, independent of any attached presentation.
/// Retention covers incomplete calls only; committed history stays in the log.
final class SessionObservationSource implements WatchObserver {
  late final observation = SessionObservation._(this);
  AgentLoop? _loop;
  int? _handle;
  StreamSubscription<ToolActivity>? _activity;
  final _listeners = <Object, void Function(SessionObservationEvent)>{};
  final _tail = <SessionObservationEvent>[];
  final _snapshots = Expando<SessionEntry>();
  final _calls = Expando<ToolUse>();
  int _retainedCharacters = 0;
  static const _retentionLimit = 262144;
  static const _eventLimit = 4096;
  bool _previewTruncated = false;
  bool _closed = false;

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
      } else if (entry is MessageAppendedEntry) {
        if (entry.message.role == Role.assistant) {
          _tail.removeWhere((e) => e is ObservedModel);
        }
        final completed = entry.message.content
            .whereType<ToolResultBlock>()
            .map((block) => block.toolUseId)
            .toSet();
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
    final value = _loop?.toolSchema(call.name)?.describe?.call(call.input);
    return value == null
        ? null
        : ToolDescription(
            title: value.title,
            target: value.target,
            fields: Map.unmodifiable(value.fields));
  }

  void Function() _listen(void Function(SessionObservationEvent) listener) {
    if (_closed) throw StateError('Observation is closed');
    final owner = Object();
    _listeners[owner] = listener;
    try {
      for (final entry in _loop?.log ?? <SessionEntry>[]) {
        listener(ObservedEntry(_snapshot(entry), LogEvent.replay));
      }
      for (final event in _tail.toList()) listener(event);
      if (_previewTruncated)
        listener(const ObservedModel(SawNotice(
            'Earlier live preview omitted; the completed response will reconcile it.')));
    } catch (_) {
      _listeners.remove(owner);
      rethrow;
    }
    return () => _listeners.remove(owner);
  }

  void _publish(SessionObservationEvent event) {
    for (final item in _listeners.entries.toList()) {
      if (!_listeners.containsKey(item.key)) continue;
      try {
        item.value(event);
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
  }
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

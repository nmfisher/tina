/// The provider decorator that lets a viewer watch a stream the loop is
/// already consuming.
///
/// `LlmProvider.send` yields one stream, and the loop is its only reader —
/// by the time the loop sees a finished turn, the tokens and tool calls are
/// history. [TeeProvider] wraps a real provider and forwards that stream
/// **unchanged** — same events, same order, same instances — while emitting
/// what it sees to an optional [TeeProvider.sink]: a plain callback, so this
/// file takes no dependency on any UI package (the architecture guard
/// forbids an engine package from reaching a terminal one, and a viewer
/// this generic needs no TUI types anyway).
///
/// The sighting vocabulary ([WatchEvent]) is deliberately not `StreamEvent`:
/// the loop keeps the real events, and a watcher needs a little more than
/// the stream says — a tool call's **end** is only implicit (the completion's
/// blocks) and the **completion** itself is just the last event. So the sink
/// sees `SawToolEnd` / `SawCompletion` alongside the verbatim text, thinking
/// and tool-start sightings, always in arrival order.
library;

import 'dart:async';
import 'package:tina_core/tina_core.dart';

/// What the decorator saw, in the order it saw it. The watch copy — the
/// real `StreamEvent`s keep flowing to the consumer untouched.
sealed class WatchEvent {
  const WatchEvent();
}

/// A text delta arrived.
final class SawText extends WatchEvent {
  final String text;
  const SawText(this.text);
  @override
  bool operator ==(Object other) => other is SawText && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// A thinking delta arrived. [startsBlock] mirrors the reasoning event's.
final class SawThinking extends WatchEvent {
  final String text;
  final bool startsBlock;
  const SawThinking(this.text, {this.startsBlock = false});
  @override
  bool operator ==(Object other) =>
      other is SawThinking &&
      other.text == text &&
      other.startsBlock == startsBlock;

  @override
  int get hashCode => Object.hash(text, startsBlock);
}

/// Ends a displayed thought, including a provider-truncated block.
final class SawThinkingEnd extends WatchEvent {
  const SawThinkingEnd({required this.complete});
  final bool complete;
  @override
  bool operator ==(Object other) =>
      other is SawThinkingEnd && other.complete == complete;
  @override
  int get hashCode => complete.hashCode;
}

/// A policy-layer notice arrived (retry ladder, failover). The view should
/// show why nothing is happening; the loop decides what to do about it.
final class SawNotice extends WatchEvent {
  final String text;
  const SawNotice(this.text);
  @override
  bool operator ==(Object other) => other is SawNotice && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// A tool call started.
final class SawToolStart extends WatchEvent {
  final String id;
  final String name;
  const SawToolStart({required this.id, required this.name});
  @override
  bool operator ==(Object other) =>
      other is SawToolStart && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// A tool call ended: its block appeared in a completion. Carries the same
/// id the start sighting carried.
final class SawToolEnd extends WatchEvent {
  final String id;
  final String name;
  const SawToolEnd({required this.id, required this.name});
  @override
  bool operator ==(Object other) =>
      other is SawToolEnd && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The stream completed. [stopReason] is the last completion's, or null
/// when the stream ended without one (an in-band error, a closed transport).
final class SawCompletion extends WatchEvent {
  final String? stopReason;
  const SawCompletion(this.stopReason);
  @override
  bool operator ==(Object other) =>
      other is SawCompletion && other.stopReason == stopReason;

  @override
  int get hashCode => stopReason.hashCode;
}

/// The sink a watcher supplies: one call per sighting, in arrival order.
/// Optional on [TeeProvider] — null means nobody is watching and the
/// decorator is a pure pass-through.
typedef WatchSink = void Function(WatchEvent event);

/// An [LlmProvider] that forwards its inner provider's stream unchanged and
/// emits what it sees to [sink]. With no sink (the default) it is a
/// pass-through with no behavior of its own.
///
/// A sink that throws cannot corrupt the model stream: sighting calls are
/// guarded and a throwing watcher is ignored — a broken viewer must never
/// turn into a broken turn (same rule as the log's listener errors).
final class TeeProvider implements LlmProvider {
  final LlmProvider _inner;

  /// Who is watching, or null for a pure pass-through.
  final WatchSink? sink;

  TeeProvider(this._inner, {this.sink}) : model = _inner.model;

  @override
  final String model;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    String? stop;
    // A transform forwards cancellation immediately. An async* / await-for
    // wrapper can wait for the next upstream event before propagating cancel,
    // leaving a stalled request (and its spend accounting) alive after Escape.
    return _inner
        .send(
          system: system,
          messages: messages,
          tools: tools,
        )
        .transform(StreamTransformer<StreamEvent, StreamEvent>.fromHandlers(
          handleData: (event, output) {
            _emit(_sightingsFor(event));
            if (event is MessageComplete) stop = event.stopReason;
            output.add(event);
          },
          handleDone: (output) {
            _emit([SawCompletion(stop)]);
            output.close();
          },
        ));
  }

  /// The sightings one stream event produces. A completion ends every tool
  /// call it carries — the stream itself only says "started".
  List<WatchEvent> _sightingsFor(StreamEvent event) => switch (event) {
        TextDelta(:final text) => [SawText(text)],
        ReasoningDelta(:final text, :final startsBlock) => [
            SawThinking(text, startsBlock: startsBlock)
          ],
        ReasoningEnd(:final complete) => [SawThinkingEnd(complete: complete)],
        StreamNotice(:final text) => [SawNotice(text)],
        ToolCallStart(:final id, :final name) => [
            SawToolStart(id: id, name: name)
          ],
        MessageComplete(:final content) => [
            for (final block in content)
              if (block is ToolUseBlock)
                SawToolEnd(id: block.id, name: block.name),
          ],
        // Errors are the loop's to surface.
        _ => const [],
      };

  void _emit(List<WatchEvent> sightings) {
    final sink = this.sink;
    if (sink == null) return;
    for (final sighting in sightings) {
      try {
        sink(sighting);
      } catch (_) {
        // A broken viewer is ignored, never propagated into the stream.
      }
    }
  }

  @override
  void close() => _inner.close();
}

/// Optional transient observations supplied by a provider adapter. These are
/// presentation hints; the session log remains authoritative. The loop does
/// not depend on observers, channels, or any UI.
abstract interface class WatchObserver {
  void watch(WatchEvent event);
}

/// The shared tail of every wire: turn an SSE body into yielded events,
/// with the stall watchdog and one completion built at the end.
///
/// The wires differ in their frames (Anthropic types, OpenAI deltas,
/// Gemini envelopes) but not in how a body must be pumped: chunks feed a
/// parser, mapped events yield incrementally, any gap longer than the
/// stall timeout ends the stream with a [StreamError], and the final
/// message is built once the wire says it is done — never fabricated
/// after an error or a silent close.
library;

import 'dart:async';

import 'package:tina_core/tina_core.dart';

import 'sse.dart';

/// What a wire contributes to [pumpSse]: a fresh per-response builder,
/// the frame-to-events mapping, and the end-of-response build.
class WireProtocol {
  WireProtocol({
    required this.buildBuilder,
    required this.apply,
    required this.build,
  });

  /// One builder per response, fresh state.
  final Object Function() buildBuilder;

  /// Apply one frame, appending mapped events to [out]. Returns true
  /// when the frame ended the response (Anthropic `message_stop`, an
  /// error frame, OpenAI `[DONE]`).
  final bool Function(Object builder, Map<String, dynamic> frame,
      List<StreamEvent> out) apply;

  /// The completion, once the wire is done. Null means no completion:
  /// either the wire never said done, or nothing usable was produced.
  final MessageComplete? Function(Object builder) build;
}

/// State shared between the watchdog and the frame pump: stop pumping,
/// why, and whether the wire said goodbye.
final class PumpFlag {
  bool value = false;
  bool sawStop = false;
  bool stalled = false;
}

/// The end-state every wire builder reports to [pumpSse]: a malformed
/// frame's first complaint and whether the provider ended the response
/// with an error frame. Wires mix this in so the pump can read it
/// without knowing the builder's own shape.
mixin WireBuilderState {
  String? badFrame;

  /// True once an error frame was seen: the response ended in the
  /// provider's eyes, the error was already yielded, and no completion
  /// may be fabricated after it.
  bool errored = false;
}

/// Pump [body] through an [SseParser] mapping frames with [protocol],
/// yielding events as they arrive, and yield the completion last when
/// the wire ended cleanly. Errors are stream events; nothing throws.
Stream<StreamEvent> pumpSse(
  Stream<List<int>> body,
  WireProtocol protocol, {
  required Duration stallTimeout,
}) async* {
  final builder = protocol.buildBuilder();
  final mapped = <StreamEvent>[];
  final flag = PumpFlag();
  final parser = SseParser(
    onFrame: (frame) {
      if (protocol.apply(builder, frame, mapped)) {
        flag.value = true;
        flag.sawStop = true;
      }
    },
    onBadFrame: (problem) {
      final b = builder as WireBuilderState;
      b.badFrame ??= problem;
    },
  );
  final queue = StreamController<StreamEvent>(sync: true);
  final completions = StreamController<StreamEvent>(sync: true);

  Timer? watchdog;
  void resetWatchdog() {
    watchdog?.cancel();
    watchdog = Timer(stallTimeout, () {
      if (flag.value) return;
      flag.value = true;
      flag.stalled = true;
      queue.add(StreamError('stream stalled: no bytes for $stallTimeout'));
      queue.close();
      completions.close();
    });
  }

  // Pump the body in the background, feeding the parser and forwarding
  // mapped events; the generator consumes the queue with the watchdog
  // armed. This keeps yields incremental: a delta goes out when it
  // arrives, not when the body ends.
  unawaited(() async {
    try {
      resetWatchdog();
      await for (final chunk in body) {
        if (flag.value) break;
        resetWatchdog();
        parser.add(chunk);
        for (final e in mapped) {
          queue.add(e);
        }
        mapped.clear();
        if (flag.value) break; // end-of-response seen inside onFrame
      }
      // A final frame can flip the end flag during finish(); map its
      // events before deciding how the body ended.
      for (final e in mapped) {
        queue.add(e);
      }
      mapped.clear();
      parser.finish();
      for (final e in mapped) {
        queue.add(e);
      }
      mapped.clear();
      watchdog?.cancel();
      // How the body ended decides what completes the stream.
      if (flag.stalled) {
        // The watchdog already delivered the stall error.
        return;
      }
      final b = builder as WireBuilderState;
      if (b.badFrame != null) {
        // A bad frame surfaces no matter how the body ended — a clean
        // end followed by junk still gets reported.
        queue.add(StreamError('bad frame in stream: ${b.badFrame}'));
        return;
      }
      if (flag.sawStop && !b.errored) {
        final completion = protocol.build(builder);
        if (completion != null) completions.add(completion);
        return;
      }
      if (b.errored) {
        // The provider ended the response with an error frame; it was
        // already yielded. No completion is fabricated after it.
        return;
      }
      // The transport closed without an end: not a completion.
      queue.add(StreamError('stream ended before the wire finished'));
    } catch (e) {
      queue.add(StreamError('stream failed: $e'));
    } finally {
      watchdog?.cancel();
      await queue.close();
      await completions.close();
    }
  }());

  await for (final e in queue.stream) {
    yield e;
  }
  // Whatever the reason the queue closed, the completions controller
  // closed with it — empty unless a clean stop built one.
  await for (final e in completions.stream) {
    yield e;
  }
}

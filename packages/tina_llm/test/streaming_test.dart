// The pump's contract: nothing throws. A stall closes the queue with a
// terminal error; anything the body does afterward (a late transport
// failure, a trailing frame) must be dropped, not thrown into the
// unawaited pump closure. These tests replay the interleaving that once
// printed `Bad state: Cannot add event after closing` into the TUI.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

/// A minimal wire for driving pumpSse directly: `delta` frames emit
/// text, `over` ends the response. Builder shape satisfies the
/// WireBuilderState cast the pump performs.
final class _TestBuilder with WireBuilderState {}

final WireProtocol _protocol = WireProtocol(
  buildBuilder: _TestBuilder.new,
  apply: (b, frame, out) {
    switch (frame['type']) {
      case 'delta':
        out.add(TextDelta(frame['text'] as String));
      case 'over':
        return true;
    }
    return false;
  },
  build: (b) => MessageComplete(
      content: [TextBlock('done')], stopReason: 'end_turn'),
);

List<int> _frame(String json) => utf8.encode('data: $json\n\n');

void main() {
  test('a stall followed by a late body error yields only the stall error',
      () async {
    final body = StreamController<List<int>>(sync: true);

    final collected = pumpSse(
      body.stream,
      _protocol,
      stallTimeout: const Duration(milliseconds: 50),
    ).toList();

    // Text arrives, then the wire goes silent well past the timeout:
    // the watchdog fires, emits the stall error, closes the queue.
    body.add(_frame('{"type":"delta","text":"hi"}'));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // The dying connection throws after the stall already ended the
    // stream. Before the emit guard this escaped the pump as an
    // unhandled `Bad state: Cannot add event after closing`.
    body.addError(StateError('connection reset by peer'));
    await body.close();

    final events = await collected;
    expect(events, hasLength(2));
    expect(events[0], isA<TextDelta>());
    expect(events[1], isA<StreamError>());
    final error = events[1] as StreamError;
    expect(error.error.toString(), contains('stream stalled'));
    expect(error.transient, isTrue,
        reason: 'stalls are retryable; the CLI treats them as such');
  });

  test('a stall followed by a trailing clean close still ends with the stall',
      () async {
    final body = StreamController<List<int>>(sync: true);

    final collected = pumpSse(
      body.stream,
      _protocol,
      stallTimeout: const Duration(milliseconds: 50),
    ).toList();

    body.add(_frame('{"type":"delta","text":"hi"}'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    // The body then ends without an error and without an end frame —
    // parser.finish() maps nothing, and no duplicate error is emitted.
    await body.close();

    final events = await collected;
    expect(events, hasLength(2));
    expect(events[1], isA<StreamError>());
    expect((events[1] as StreamError).error.toString(),
        contains('stream stalled'));
  });

  test('a clean response still yields deltas then the completion', () async {
    final collected = pumpSse(
      Stream.fromIterable([
        _frame('{"type":"delta","text":"hel"}'),
        _frame('{"type":"delta","text":"lo"}'),
        _frame('{"type":"over"}'),
      ]),
      _protocol,
      stallTimeout: const Duration(seconds: 5),
    ).toList();

    final events = await collected;
    expect(events, hasLength(3));
    expect(events[0], isA<TextDelta>().having((d) => d.text, 'text', 'hel'));
    expect(events[1], isA<TextDelta>().having((d) => d.text, 'text', 'lo'));
    expect(events[2], isA<MessageComplete>());
  });
}

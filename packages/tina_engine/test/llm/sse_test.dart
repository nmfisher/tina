import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// Direct tests for the SSE line parser shared by every streaming provider.
/// It's indirectly exercised by the provider tests, but pinned here so the
/// contract (data: filtering, [DONE] termination, UTF-8) is explicit and cheap
/// to assert.
void main() {
  // Encode a raw SSE frame string into the byte stream parseSse consumes.
  Stream<List<int>> sse(String raw) =>
      Stream.fromIterable([utf8.encode(raw)]);

  group('parseSse', () {
    test('yields the payload of each data: line, in order', () async {
      final out = await parseSse(sse([
        'data: one',
        'data: two',
        'data: three',
        '',
      ].join('\n'))).toList();
      expect(out, ['one', 'two', 'three']);
    });

    test('ignores event:, comments, retry:, and blank lines', () async {
      final out = await parseSse(sse([
        'event: message',
        ': a comment',
        '',
        'data: kept',
        '',
        'retry: 5000',
        'data: also-kept',
        '',
      ].join('\n'))).toList();
      expect(out, ['kept', 'also-kept']);
    });

    test('terminates on data: [DONE] without yielding it', () async {
      final out = await parseSse(sse([
        'data: before',
        'data: [DONE]',
        'data: after',
        '',
      ].join('\n'))).toList();
      expect(out, ['before']); // stops at [DONE]; 'after' never read
    });

    test('a lone [DONE] yields nothing', () async {
      final out = await parseSse(sse('data: [DONE]\n')).toList();
      expect(out, isEmpty);
    });

    test('trims leading spaces after the prefix, keeps trailing', () async {
      // parseSse does substring(5).trimLeft() — only leading whitespace is
      // removed, so trailing spaces survive (a payload may legitimately end
      // with them).
      final out = await parseSse(sse('data:   hello   \n')).toList();
      expect(out, ['hello   ']);
    });

    test('decodes UTF-8 multibyte payloads intact', () async {
      final out = await parseSse(sse('data: {"box":"┌─┐"}\n')).toList();
      expect(out, ['{"box":"┌─┐"}']);
    });

    test('a line without the data: prefix is skipped', () async {
      final out = await parseSse(sse([
        'notdata: x',
        'data: y',
        '',
      ].join('\n'))).toList();
      expect(out, ['y']);
    });
  });
}

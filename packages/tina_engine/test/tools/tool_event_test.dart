import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('ToolStartEvent', () {
    test('carries name, id, input; conversationId defaults to null', () {
      const e = ToolStartEvent('bash', 't1', {'command': 'ls'});
      expect(e.toolName, 'bash');
      expect(e.toolId, 't1');
      expect(e.input, {'command': 'ls'});
      expect(e.conversationId, isNull);
    });

    test('conversationId is set when passed', () {
      const e = ToolStartEvent('bash', 't1', {}, conversationId: 'c1');
      expect(e.conversationId, 'c1');
    });
  });

  group('ToolOutputEvent', () {
    test('defaults stderr to false', () {
      const e = ToolOutputEvent('bash', 't1', 'chunk');
      expect(e.stderr, isFalse);
      expect(e.chunk, 'chunk');
    });

    test('carries stderr=true when set', () {
      const e = ToolOutputEvent('bash', 't1', 'err', stderr: true);
      expect(e.stderr, isTrue);
    });
  });

  group('ToolCompleteEvent', () {
    test('carries result + isError + conversationId', () {
      const e = ToolCompleteEvent('bash', 't1',
          isError: true, result: 'boom', conversationId: 'c9');
      expect(e.isError, isTrue);
      expect(e.result, 'boom');
      expect(e.conversationId, 'c9');
    });

    test('a non-error result round-trips', () {
      const e = ToolCompleteEvent('grep', 'g1', isError: false, result: 'ok');
      expect(e.isError, isFalse);
      expect(e.result, 'ok');
    });
  });

  test('the lifecycle events share toolName/toolId for one call', () {
    const start = ToolStartEvent('grep', 'g1', {});
    const out = ToolOutputEvent('grep', 'g1', 'x');
    const done =
        ToolCompleteEvent('grep', 'g1', isError: false, result: 'r');
    for (final e in [start, out, done]) {
      expect(e.toolName, 'grep');
      expect(e.toolId, 'g1');
    }
  });
}

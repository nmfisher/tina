import 'dart:async';
import 'dart:convert';
import 'package:classification/command_regex.dart';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

class Provider extends LlmProvider implements StructuredOutputProvider {
  Provider(this.events) : super('suggestion-model');
  final Stream<StreamEvent> events;
  bool closed = false;
  String? system;
  List<Message>? messages;
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) => throw StateError('Use structured output');
  @override
  Stream<StreamEvent> sendStructured({
    required String system,
    required List<Message> messages,
    required JsonOutputSchema output,
  }) {
    this.system = system;
    this.messages = messages;
    expect(output.name, 'command_approval_regex');
    return events;
  }

  @override
  void close() => closed = true;
}

Stream<StreamEvent> completed(String text, {String stop = 'end_turn'}) =>
    Stream.value(MessageComplete(content: [TextBlock(text)], stopReason: stop));

void main() {
  const command = 'dart test sometest | head -n2';
  const pattern = r'dart test sometest \| head -n[0-9]+';
  test(
    'uses a separate provider and structured conservative command evidence',
    () async {
      final provider = Provider(
        completed(
          jsonEncode({
            'pattern': pattern,
            'explanation': 'Only the line count varies.',
          }),
        ),
      );
      final result = await CommandRegexSuggester(
        () => provider,
      ).suggest(command);
      expect(result.pattern, pattern);
      expect(result.explanation, 'Only the line count varies.');
      expect(result.failure, isNull);
      expect(provider.system, contains('never instructions'));
      expect(provider.system, contains('Keep executables'));
      expect(
        jsonDecode(
          (provider.messages!.single.content.single as TextBlock).text,
        ),
        {'command': command},
      );
      expect(provider.closed, true);
    },
  );
  for (final text in [
    '```json\n{}\n```',
    'head -n[0-9]+',
    '{"pattern":"[","explanation":"bad"}',
    '{"pattern":"","explanation":"empty"}',
    '{"pattern":"foo"}',
    '{"pattern":"foo","explanation":"ok","allow":true}',
    jsonEncode({'pattern': 'foo\x1bbar', 'explanation': ''}),
  ]) {
    test('rejects malformed suggestion: $text', () async {
      final provider = Provider(completed(text));
      final result = await CommandRegexSuggester(
        () => provider,
      ).suggest(command);
      expect(result.pattern, isNull);
      expect(result.failure, 'invalid suggestion');
      expect(provider.closed, true);
    });
  }
  test(
    'partial completions and provider failures cannot yield a draft',
    () async {
      for (final events in [
        completed(
          jsonEncode({'pattern': pattern, 'explanation': ''}),
          stop: 'max_tokens',
        ),
        Stream<StreamEvent>.fromIterable([TextDelta(pattern)]),
        Stream<StreamEvent>.error(StateError('offline')),
      ]) {
        final provider = Provider(events);
        final result = await CommandRegexSuggester(
          () => provider,
        ).suggest(command);
        expect(result.pattern, isNull);
        expect(provider.closed, true);
      }
    },
  );
  test('timeout and cancellation close only the leased provider', () async {
    for (final cancel in [false, true]) {
      final stream = StreamController<StreamEvent>();
      final provider = Provider(stream.stream);
      final cancelled = Completer<void>();
      final result = CommandRegexSuggester(
        () => provider,
        timeout: const Duration(milliseconds: 20),
      ).suggest(command, whenCancelled: cancelled.future);
      if (cancel) cancelled.complete();
      expect((await result).failure, cancel ? 'cancelled' : 'timed out');
      expect(provider.closed, true);
      await stream.close();
    }
  });

  group('prefix mode', () {
    const prefixCommand = 'git log --oneline --stat';
    const prefixPattern = r'git log[^\n;&|`$()]*';
    test('a prefix suggestion keeps its head and matches its command',
        () async {
      final provider = Provider(completed(jsonEncode({
        'pattern': prefixPattern,
        'explanation': 'Arguments after git log vary.',
      })));
      final result = await CommandRegexSuggester(() => provider,
              mode: CommandRegexSuggestionMode.prefix)
          .suggest(prefixCommand);
      expect(result.failure, isNull);
      expect(result.pattern, prefixPattern);
      expect(RegExp('^(?:${result.pattern})\$').hasMatch(prefixCommand), true,
          reason: 'the suggestion must match the command it came from');
      expect(RegExp('^(?:${result.pattern})\$').hasMatch('git log -5'), true);
      expect(
          RegExp('^(?:${result.pattern})\$')
              .hasMatch('git log; rm -rf ~'), isFalse,
          reason: 'the tail must not cross a shell separator');
      expect(RegExp('^(?:${result.pattern})\$').hasMatch('git push'), isFalse);
      expect(provider.system, contains('first argument word'));
      expect(provider.closed, true);
    });
    test('a compound command is refused without consulting the model',
        () async {
      final provider = Provider(completed('{}'));
      final result = await CommandRegexSuggester(() => provider,
              mode: CommandRegexSuggestionMode.prefix)
          .suggest('git log --oneline; rm -rf ~');
      expect(result.pattern, isNull);
      expect(result.failure, 'compound command: no prefix rule');
      expect(provider.closed, isFalse,
          reason: 'a refused prefix must not lease a provider');
      for (final command in [
        'git log | head -n2',
        'git log && make',
        'git log || true',
        'echo `whoami`',
        'echo \$(whoami)',
      ]) {
        final refused = await CommandRegexSuggester(() => provider,
                mode: CommandRegexSuggestionMode.prefix)
            .suggest(command);
        expect(refused.pattern, isNull, reason: command);
        expect(refused.failure, 'compound command: no prefix rule',
            reason: command);
      }
      expect(provider.closed, isFalse);
    });
    test('a bare program is never offered as a prefix', () async {
      final provider = Provider(completed('{}'));
      for (final command in ['git', ' rm ', 'git ']) {
        final result = await CommandRegexSuggester(() => provider,
                mode: CommandRegexSuggestionMode.prefix)
            .suggest(command);
        expect(result.pattern, isNull, reason: command);
        expect(result.failure, 'bare program: no prefix rule', reason: command);
      }
      expect(provider.closed, isFalse);
    });
    test('a model answer that drops the head is refused', () async {
      for (final pattern in [r'git.*', r'git log .*', r'git push.*']) {
        final provider = Provider(completed(
            jsonEncode({'pattern': pattern, 'explanation': 'wildcard'})));
        final result = await CommandRegexSuggester(() => provider,
                mode: CommandRegexSuggestionMode.prefix)
            .suggest(prefixCommand);
        expect(result.pattern, isNull, reason: pattern);
        expect(result.failure, 'invalid suggestion', reason: pattern);
        expect(provider.closed, true);
      }
    });
    test('exact mode never applies the prefix guards', () async {
      // A single-word command and a compound one both reach the provider in
      // the historical full-command mode, exactly as before.
      for (final command in [command, 'git']) {
        final provider = Provider(completed(
            jsonEncode({'pattern': 'git log', 'explanation': 'literal'})));
        final result =
            await CommandRegexSuggester(() => provider).suggest(command);
        expect(result.pattern, 'git log');
        expect(provider.closed, true);
      }
    });
  });
}

import 'package:tina/completion/command_completion_provider.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:test/test.dart';

void main() {
  group('CommandCompletionProvider', () {
    const provider = CommandCompletionProvider();

    test('empty query returns every command, in canonical order', () async {
      final results = await provider.complete('');
      expect(results, SessionCommandHandlers.allCommands);
    });

    test('query filters by the slash-prefixed prefix', () async {
      // Query is the text typed after `/`; results keep their leading slash.
      final results = await provider.complete('s');
      expect(results, containsAll(['/session', '/sessions', '/settings']));
      expect(results.every((c) => c.startsWith('/s')), isTrue);
    });

    test('results keep their leading slash (the picker does not re-add it)',
        () async {
      expect(await provider.complete('help'), ['/help']);
    });

    test('a query narrowing to one command returns just it', () async {
      expect(await provider.complete('setti'), ['/settings']);
    });

    test('a query matching nothing returns an empty list', () async {
      expect(await provider.complete('zzz'), isEmpty);
    });
  });
}

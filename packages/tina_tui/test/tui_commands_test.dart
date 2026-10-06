// The TUI's command front end: the pure dispatch decision, and the
// presentation of whatever the registry holds — no command name appears
// in this package's source.
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  final registry = Commands()
    ..publish(Command(
      name: 'mode',
      description: 'switch the permission mode',
      handler: (_) {},
    ))
    ..publish(Command(
      name: 'help',
      description: 'list the commands',
      handler: (_) {},
    ));

  group('dispatchLine: the pure function', () {
    test('a plugin prefix alias passes the complete shell command', () {
      final commands = Commands()
        ..publish(Command(
            name: 'shell',
            description: 'shell',
            inputPrefix: '!',
            handler: (_) {}));
      final d =
          dispatchLine(commands, '  !printf "one two" | cat  ') as RunCommand;
      expect(d.command.name, 'shell');
      expect(d.argument, 'printf "one two" | cat');
      expect((dispatchLine(commands, '/shell echo hi') as RunCommand).argument,
          'echo hi');
      expect(dispatchLine(Commands(), '!echo hi'), const PlainLine('!echo hi'));
    });
    test('a command line maps to the right command with its argument', () {
      final d = dispatchLine(registry, '/mode read-only');
      expect(d, isA<RunCommand>());
      final run = d as RunCommand;
      expect(run.command.name, 'mode');
      expect(run.argument, 'read-only');
    });

    test('the argument is everything after the word, trimmed', () {
      final d = dispatchLine(registry, '/mode   read-only  ') as RunCommand;
      expect(d.argument, 'read-only');
      expect(d.command.name, 'mode');
    });

    test('a bare command word runs with an empty argument', () {
      final d = dispatchLine(registry, '/mode') as RunCommand;
      expect(d.command.name, 'mode');
      expect(d.argument, '');
    });

    test('surrounding whitespace changes nothing', () {
      final d = dispatchLine(registry, '  /help  ') as RunCommand;
      expect(d.command.name, 'help');
      expect(d.argument, '');
    });

    test('a normal line maps to none', () {
      final d = dispatchLine(registry, 'write the file please');
      expect(d, isA<PlainLine>());
      expect((d as PlainLine).text, 'write the file please');
    });

    test('an empty line is plain and empty — no turn', () {
      final d = dispatchLine(registry, '   ');
      expect(d, const PlainLine(''));
    });

    test('a / with no word is unknown, not swallowed', () {
      final d = dispatchLine(registry, '/');
      expect(d, isA<UnknownCommand>());
      expect((d as UnknownCommand).name, '');
    });

    test('an unknown command is reported, not swallowed', () {
      final d = dispatchLine(registry, '/nope args') as UnknownCommand;
      expect(d.name, 'nope');
      final seen = <String>[];
      d.report(seen.add);
      expect(seen.single, 'unknown command: /nope');
    });
  });

  group('presentation: read the registry, name nothing', () {
    test('the list comes from Commands.all, sorted, with hints', () {
      final rows = commandListRows(registry);
      expect(rows, [
        '/help — list the commands',
        '/mode — switch the permission mode',
      ]);
    });

    test(
        'a command registered by a plugin is found without TUI code '
        'naming it', () {
      // A registry no TUI source has seen the contents of: publish at
      // runtime, discover at runtime.
      final fresh = Commands()
        ..publish(Command(
          name: 'sprouted',
          description: 'added by a plugin after the TUI was built',
          handler: (_) {},
        ));
      final d = dispatchLine(fresh, '/sprouted now');
      expect(d, isA<RunCommand>());
      expect(commandListRows(fresh).single, startsWith('/sprouted — '));
      (d as RunCommand).run(); // the handler runs; nothing threw
    });
  });
}

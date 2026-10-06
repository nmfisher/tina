import 'dart:collection';

import 'package:tina_core/tina_core.dart';
import 'package:tina_host/tina_host.dart';
import 'package:test/test.dart';

void main() {
  group('Commands', () {
    test('prefix aliases reject duplicates and disappear with their owner', () {
      final c = Commands();
      final shell = Command(
          name: 'shell',
          description: 'shell',
          inputPrefix: '!',
          handler: (_) {});
      c.publish(shell, owner: 'test/shell');
      expect(c.matchPrefix('!echo one')?.command, same(shell));
      expect(c.matchPrefix('!echo one')?.argument, 'echo one');
      expect(
          () => c.publish(Command(
              name: 'other',
              description: 'other',
              inputPrefix: '!',
              handler: (_) {})),
          throwsStateError);
      expect(c['other'], isNull);
      c.removeOwner('test/shell');
      expect(c.matchPrefix('!echo one'), isNull);
      expect(c['shell'], isNull);
      c.publish(shell);
    });
    test('prefix matching prefers the most specific registered prefix', () {
      final c = Commands()
        ..publish(Command(
            name: 'one', description: 'one', inputPrefix: '!', handler: (_) {}))
        ..publish(Command(
            name: 'two',
            description: 'two',
            inputPrefix: '!!',
            handler: (_) {}));
      expect(c.matchPrefix('!!argument')?.command.name, 'two');
      expect(c.matchPrefix('!!argument')?.argument, 'argument');
      expect(c.matchPrefix('ordinary text'), isNull);
    });
    test('invalid prefix aliases fail before publishing the command', () {
      for (final prefix in ['', '/', '/shell', '! ']) {
        final c = Commands();
        expect(
            () => c.publish(Command(
                name: 'bad',
                description: 'bad',
                inputPrefix: prefix,
                handler: (_) {})),
            throwsArgumentError);
        expect(c.all, isEmpty);
      }
    });
    test('publish and look up by name', () {
      final written = <String>[];
      final c = Commands()..publish(_echoCommand(written, name: 'mode'));
      expect(c['mode'], isNotNull);
      expect(c['nope'], isNull);
    });
    test('re-publishing a name throws', () {
      final written = <String>[];
      final c = Commands()..publish(_echoCommand(written));
      expect(
          () => c.publish(_echoCommand(written)), throwsA(isA<StateError>()));
    });
    test('all is sorted by name', () {
      final written = <String>[];
      final c = Commands()
        ..publish(_echoCommand(written, name: 'quit'))
        ..publish(_echoCommand(written, name: 'mode'));
      expect([for (final x in c.all) x.name], ['mode', 'quit']);
    });
    test("the handler receives the argument text and returns nothing", () {
      final written = <String>[];
      final c = Commands()..publish(_echoCommand(written));
      c['echo']!.handler('one two');
      expect(written, ['echo: one two']);
    });
  });

  group('Terminal', () {
    test('a capturing terminal records lines and answers asks', () async {
      final t = _CaptureTerminal();
      t.writeln('one');
      t.writeln();
      t.writeln('two');
      expect(t.lines, ['one', '', 'two']);
      t.queue = Queue.of(['  read-only  ']);
      expect(await t.ask('mode? '), '  read-only  ');
      expect(t.prompts, ['mode? ']);
    });
  });
}

Command _echoCommand(List<String> written, {String name = 'echo'}) => Command(
      name: name,
      description: 'write the argument back',
      handler: (argument) => written.add('$name: $argument'),
    );

final class _CaptureTerminal implements Terminal {
  final lines = <String>[];
  final prompts = <String>[];
  Queue<String>? queue;

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) {
    prompts.add(prompt);
    // Deliberately untrimmed: the real terminal owns the trim, so a fake
    // that skips it lets an untrimmed string slip into a test.
    return Future.value(queue?.removeFirst() ?? '');
  }
}

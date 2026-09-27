import 'dart:collection';

import 'package:tina_services/tina_services.dart';
import 'package:test/test.dart';

void main() {
  group('Services', () {
    test('put then get by type returns the instance', () {
      final s = Services()..put('hello');
      expect(s.get<String>(), 'hello');
    });
    test('get on a missing service throws StateError naming the type', () {
      final s = Services();
      expect(() => s.get<Terminal>(), throwsA(isA<StateError>()));
      expect(() => s.get<Terminal>(),
          throwsA(predicate((e) => '$e'.contains('Terminal'))));
    });
    test('registration order does not matter: hold the locator first, '
        'resolve at use', () {
      final s = Services();
      // No service yet — the locator is still handed out (a plugin holds
      // it at construction), and resolving now would throw. Resolving
      // after registration is the same call, different moment.
      expect(() => s.get<Commands>(), throwsA(isA<StateError>()));
      final c = Commands();
      s.put(c);
      expect(s.get<Commands>(), same(c));
    });
    test('different types coexist; re-register replaces', () {
      final term = _CaptureTerminal();
      final cmds = Commands();
      final s = Services()
        ..put<Terminal>(term)
        ..put<Commands>(cmds);
      expect(s.get<Terminal>(), same(term));
      expect(s.get<Commands>(), same(cmds));
      final second = _CaptureTerminal();
      s.put<Terminal>(second);
      expect(s.get<Terminal>(), same(second));
    });
    test('maybe returns null for a missing service', () {
      final s = Services();
      expect(s.maybe<Commands>(), isNull);
      final c = Commands();
      s.put(c);
      expect(s.maybe<Commands>(), same(c));
    });
  });

  group('Commands', () {
    test('publish and look up by name', () {
      final written = <String>[];
      final c = Commands()..publish(_echoCommand(written, name: 'mode'));
      expect(c['mode'], isNotNull);
      expect(c['nope'], isNull);
    });
    test('re-publishing a name throws', () {
      final written = <String>[];
      final c = Commands()..publish(_echoCommand(written));
      expect(() => c.publish(_echoCommand(written)), throwsA(isA<StateError>()));
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

Command _echoCommand(List<String> written, {String name = 'echo'}) =>
    Command(
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

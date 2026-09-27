import 'dart:collection';

import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

void main() {
  group('the mode vocabulary', () {
    test('the two words map to the two modes', () {
      expect(ModeCommandPlugin.parseMode('normal'), PermissionMode.normal);
      expect(
          ModeCommandPlugin.parseMode('read-only'), PermissionMode.readOnly);
    });
    test('the argument is trimmed before the word is matched', () {
      expect(
          ModeCommandPlugin.parseMode(' read-only '), PermissionMode.readOnly);
      expect(ModeCommandPlugin.parseMode('readonly'), isNull);
      expect(ModeCommandPlugin.parseMode(''), isNull);
    });
  });

  group('the /mode command', () {
    test('published under Commands with the vocabulary as its help line',
        () {
      final services = Services()
        ..put<Terminal>(_CaptureTerminal())
        ..put<Commands>(Commands())
        ..put<ModeControl>(_FakeControl().control);
      ModeCommandPlugin(services).register();

      final commands = services.get<Commands>();
      expect(commands['mode'], isNotNull);
      expect(commands['mode']!.description,
          'switch the permission mode, argument: normal or read-only');
      expect([for (final c in commands.all) c.name], ['mode']);
    });
    test('the handler flips the mode control and tells the terminal', () {
      final services = Services();
      final fake = _FakeControl();
      final terminal = _CaptureTerminal();
      services
        ..put<Terminal>(terminal)
        ..put<Commands>(Commands())
        ..put<ModeControl>(fake.control);
      ModeCommandPlugin(services).register();

      services.get<Commands>()['mode']!.handler('read-only');

      expect(fake.control.mode, PermissionMode.readOnly);
      expect(terminal.lines, ['mode: read-only']);
    });
    test('a refused word changes nothing and says so — never a throw', () {
      final services = Services();
      final fake = _FakeControl();
      final terminal = _CaptureTerminal();
      services
        ..put<Terminal>(terminal)
        ..put<Commands>(Commands())
        ..put<ModeControl>(fake.control);
      ModeCommandPlugin(services).register();
      final handler = services.get<Commands>()['mode']!.handler;

      expect(() => handler('wat'), returnsNormally);
      expect(fake.control.mode, PermissionMode.normal,
          reason: 'an invalid argument changes nothing');
      expect(terminal.lines, ['no mode named wat']);

      // A bare /mode shows the mode; it changes nothing.
      handler('');
      expect(terminal.lines.last, 'mode: normal');
      expect(fake.control.mode, PermissionMode.normal);
    });
    test('registration order does not matter: the control is resolved at use',
        () {
      final services = Services()
        ..put<Terminal>(_CaptureTerminal())
        ..put<Commands>(Commands());
      // No ModeControl yet — constructing and registering is still fine.
      ModeCommandPlugin(services).register();
      expect(services.get<Commands>()['mode'], isNotNull);

      final fake = _FakeControl();
      services.put<ModeControl>(fake.control);
      services.get<Commands>()['mode']!.handler('read-only');
      expect(fake.control.mode, PermissionMode.readOnly,
          reason: 'the command reads the locator when it runs, not before');
    });
    test('re-registering the same plugin is a no-op, not a registry throw',
        () {
      final services = Services()
        ..put<Terminal>(_CaptureTerminal())
        ..put<Commands>(Commands())
        ..put<ModeControl>(_FakeControl().control);
      final plugin = ModeCommandPlugin(services);
      plugin.register();
      plugin.register();
      expect(services.get<Commands>()['mode'], isNotNull);
    });
    test('two plugins publishing one word is a wiring bug: it throws', () {
      final services = Services()
        ..put<Terminal>(_CaptureTerminal())
        ..put<Commands>(Commands())
        ..put<ModeControl>(_FakeControl().control);
      ModeCommandPlugin(services).register();
      expect(() => services.get<Commands>().publish(Command(
            name: 'mode',
            description: 'the other one',
            handler: (_) {},
          )), throwsA(isA<StateError>()));
    });

    test('headless — no terminal registered — the flip is substance, the '
        'tell is dropped', () {
      final services = Services();
      final fake = _FakeControl();
      services
        ..put<Commands>(Commands())
        ..put<ModeControl>(fake.control);
      ModeCommandPlugin(services).register();

      // Every argument shape runs: bare, junk, a real word. None asks —
      // nothing here ever asks — and none throws for the missing
      // terminal.
      final handler = services.get<Commands>()['mode']!.handler;
      expect(() => handler(''), returnsNormally);
      expect(() => handler('sideways'), returnsNormally);
      expect(() => handler('read-only'), returnsNormally);
      expect(fake.control.mode, PermissionMode.readOnly,
          reason: 'the flip still happened');
    });
  });
}

final class _FakeControl {
  PermissionMode _mode = PermissionMode.normal;

  /// The real contract over a fake authority — ModeControl is an
  /// interface, so the test stands one up without a filesystem.
  ModeControl get control => _ModeControlView(this);
}

final class _ModeControlView implements ModeControl {
  _ModeControlView(this.fake);
  final _FakeControl fake;

  @override
  PermissionMode get mode => fake._mode;
  @override
  set mode(PermissionMode value) => fake._mode = value;
}

final class _CaptureTerminal implements Terminal {
  final lines = <String>[];
  final prompts = <String>[];
  Queue<String>? queue;

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) {
    prompts.add(prompt);
    return Future.value(queue?.removeFirst() ?? '');
  }
}

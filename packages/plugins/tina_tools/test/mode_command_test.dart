import 'dart:collection';
import 'package:tina_core/tina_core.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

void main() {
  test('mode vocabulary parses and formats the supported modes', () {
    expect(ModeCommandPlugin.parseMode('normal'), PermissionMode.normal);
    expect(ModeCommandPlugin.parseMode(' read-only '), PermissionMode.readOnly);
    expect(ModeCommandPlugin.parseMode('readonly'), isNull);
    expect(ModeCommandPlugin.parseMode(''), isNull);
    expect(ModeCommandPlugin.wordFor(PermissionMode.readOnly), 'read-only');
  });
  test('command switches the injected control and reports to its terminal',
      () async {
    final fake = _FakeControl();
    final terminal = _CaptureTerminal();
    final plugin = ModeCommandPlugin(mode: fake.control, terminal: terminal);
    final command = plugin.commands.single;
    expect(command.name, 'mode');
    expect(command.description, contains('normal or read-only'));
    await command.handler('read-only');
    expect(fake.control.mode, PermissionMode.readOnly);
    expect(terminal.lines, ['mode: read-only']);
    await command.handler('sideways');
    expect(fake.control.mode, PermissionMode.readOnly);
    expect(terminal.lines.last, 'no mode named sideways');
    await command.handler('');
    expect(terminal.lines.last, 'mode: read-only');
    expect(terminal.prompts, isEmpty);
  });
  test('a headless command still switches mode', () async {
    final fake = _FakeControl();
    final command = ModeCommandPlugin(mode: fake.control).commands.single;
    await command.handler('');
    await command.handler('invalid');
    await command.handler('read-only');
    expect(fake.control.mode, PermissionMode.readOnly);
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

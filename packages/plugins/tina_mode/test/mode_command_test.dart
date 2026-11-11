import 'dart:collection';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:test/test.dart';

void main() {
  test('mode vocabulary parses and formats the supported modes', () {
    expect(ModePlugin.parseMode('ask'), PermissionMode.approve);
    expect(ModePlugin.parseMode(' read-only '), PermissionMode.approve);
    expect(ModePlugin.parseMode('readonly'), isNull);
    expect(ModePlugin.parseMode(''), isNull);
    expect(ModePlugin.wordFor(PermissionMode.approve), 'approve');
    expect(ModePlugin.wordFor(PermissionMode.yolo), 'yolo');
    // yolo is start-time only: not selectable via /mode.
    expect(ModePlugin.parseMode('yolo'), isNull);
    expect(ModePlugin.modeWords, isNot(contains('yolo')));
  });
  test(
    'command switches the injected control and reports to its terminal',
    () async {
      final terminal = _CaptureTerminal();
      final plugin = ModePlugin(terminal: terminal);
      final command = plugin.commands.single;
      expect(command.name, 'mode');
      expect(command.description, contains('approve, auto'));
      await command.handler('approve');
      expect(plugin.mode, PermissionMode.approve);
      expect(terminal.lines, ['mode: approve']);
      await command.handler('sideways');
      expect(plugin.mode, PermissionMode.approve);
      expect(terminal.lines.last, 'no mode named sideways');
      await command.handler('');
      expect(terminal.lines.last, 'mode: approve');
      expect(terminal.prompts, isEmpty);
    },
  );
  test('a headless command still switches mode', () async {
    final fake = ModePlugin();
    final plugin = fake;
    final command = plugin.commands.single;
    await command.handler('');
    await command.handler('invalid');
    await command.handler('approve');
    expect(plugin.mode, PermissionMode.approve);
  });
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

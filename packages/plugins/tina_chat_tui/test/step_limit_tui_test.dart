import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'console_test.dart' show Io;

void main() {
  test('settings save globally, reject invalid values, and detach cleanly',
      () async {
    final directory = Directory.systemTemp.createTempSync('step-limit-ui-');
    final io = Io();
    final screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    final context = ConsoleContext(screen: screen, editor: editor);
    final plugin =
        StepLimitConsolePlugin(configPath: '${directory.path}/config');
    try {
      plugin.attachConsole(context);
      final field =
          context.settings.sections.single.build().single as SettingText;
      expect(field.label, contains('global; 0 = unlimited'));
      expect(field.read(), '0');
      await field.change('32');
      expect(field.read(), '32');
      expect(() => field.change('-1'), throwsFormatException);
      expect(() => field.change('1.5'), throwsFormatException);
      expect(field.read(), '32');
      plugin.detachConsole();
      expect(context.settings.sections, isEmpty);
      plugin.attachConsole(context);
      expect(
          (context.settings.sections.single.build().single as SettingText)
              .read(),
          '32');
    } finally {
      plugin.closeSession();
      editor.close(reportLatency: false);
      screen.dispose();
      unawaited(io.input.close());
      directory.deleteSync(recursive: true);
    }
  });
}

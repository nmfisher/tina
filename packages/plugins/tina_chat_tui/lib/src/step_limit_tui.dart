import 'package:tina_console/tina_console.dart';
import 'package:tina_step_limit/tina_step_limit.dart';

/// Console adapter for the same policy plugin; headless callers use the base.
final class StepLimitConsolePlugin extends StepLimitPlugin
    implements ConsoleContribution {
  StepLimitConsolePlugin({required String configPath})
      : this._(StepLimitConfig(configPath));
  StepLimitConsolePlugin._(this.config) : super(readLimit: config.read);
  final StepLimitConfig config;
  void Function()? _release;

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _release = context.settings.registerSection(
      id: 'tina/step-limit',
      title: 'Step limit',
      build: () => [
        SettingText(
          id: 'max_steps_per_turn',
          label: 'Model rounds per turn (global; 0 = unlimited)',
          read: () => config.read().toString(),
          change: (text) {
            config.save(StepLimitConfig.validate(int.tryParse(text.trim())));
            context.settings.refresh();
          },
        ),
      ],
    );
  }

  @override
  void repaintConsole() {}

  @override
  void detachConsole() {
    _release?.call();
    _release = null;
  }

  @override
  void closeSession() => detachConsole();
}

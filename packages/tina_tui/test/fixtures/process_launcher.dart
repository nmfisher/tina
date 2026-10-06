import 'package:tina_tui/tina_tui.dart';

Future<void> main(List<String> arguments) async {
  if (!await initializeProcessLauncher(arguments)) {
    throw StateError('Expected an internal process launch');
  }
}

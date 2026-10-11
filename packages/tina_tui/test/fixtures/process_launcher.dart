// The exec trampoline the tests configure. It must reach `main` fast: the
// captured launcher boots this file for every spawned command, and these
// tests grant 10s per command. Importing the package barrel pulls the whole
// TUI into each spawn's JIT compile (~10s on 4 cores, more on CI) and races
// those deadlines — import the narrow launcher library instead (~1.5s).
import 'package:tina_tui/src/process_launcher.dart';

Future<void> main(List<String> arguments) async {
  if (!await initializeProcessLauncher(arguments)) {
    throw StateError('Expected an internal process launch');
  }
}

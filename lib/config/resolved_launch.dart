import 'runtime_config.dart';
import 'terminal_config.dart';
import 'startup_options.dart';

/// Resolved root inputs. Explicit model-source metadata lives in runtime.modelExplicit.
class ResolvedLaunch {
  final RuntimeConfig runtime;
  final TerminalConfig terminal;
  final StartupOptions startup;
  const ResolvedLaunch({
    required this.runtime,
    required this.terminal,
    required this.startup,
  });
}

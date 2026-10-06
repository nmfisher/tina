import 'dart:io';

/// The application's exec trampoline. It drops the inherited controlling
/// terminal before exec, while keeping normal pipes, PID and exit status.
/// Install at the executable entry point, before assembling any plugins.
({String executable, List<String> arguments})? _launcher;

void configureCapturedProcessLauncher(
    String executable, List<String> arguments) {
  _launcher = (executable: executable, arguments: List.unmodifiable(arguments));
}

/// Spawn with captured stdio. Redirecting fd 1/2 alone is insufficient: a
/// command can otherwise reopen /dev/tty and overwrite the live UI directly.
Future<Process> startCapturedProcess(String executable, List<String> arguments,
    {String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true}) {
  final launcher = _launcher;
  if (executable.contains('\x00') || arguments.any((s) => s.contains('\x00'))) {
    throw ArgumentError('Process arguments cannot contain NUL');
  }
  return Process.start(
    launcher?.executable ?? executable,
    launcher == null
        ? arguments
        : [...launcher.arguments, executable, ...arguments],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: false,
  );
}

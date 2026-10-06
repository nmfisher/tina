import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:tina_tools/tina_tools.dart';

const _launchFlag = '--internal-process-launch';

/// Called once by the executable, before CLI parsing or terminal startup.
/// A spawned trampoline becomes the requested program via execvp, preserving
/// its PID, pipes, cwd, environment and ordinary exit/cancellation handling.
Future<bool> initializeProcessLauncher(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == _launchFlag) {
    _exec(arguments.skip(1).toList());
    return true; // Only reached when setsid/exec fails; exitCode is set below.
  }
  if (Platform.isLinux || Platform.isMacOS) {
    final packageConfig = await Isolate.packageConfig;
    configureCapturedProcessLauncher(Platform.resolvedExecutable, [
      if (Platform.script.path.endsWith('.dart')) ...[
        if (packageConfig != null) '--packages=$packageConfig',
        Platform.script.toFilePath(),
      ],
      _launchFlag,
    ]);
  }
  return false;
}

void _exec(List<String> arguments) {
  if (arguments.isEmpty || !(Platform.isLinux || Platform.isMacOS)) {
    stderr.writeln('tina: invalid process launch');
    exitCode = 127;
    return;
  }
  final libc = DynamicLibrary.process();
  final setsid =
      libc.lookupFunction<Int32 Function(), int Function()>('setsid');
  if (setsid() < 0) {
    // Never run a command with access to the UI's terminal when detachment fails.
    stderr
        .writeln('tina: could not detach child from the conversation terminal');
    exitCode = 127;
    return;
  }
  // The Dart VM ignores SIGPIPE. An ordinary exec child must regain the
  // default disposition so pipelines retain their usual broken-pipe behavior.
  final signal = libc.lookupFunction<
      Pointer<Void> Function(Int32, Pointer<Void>),
      Pointer<Void> Function(int, Pointer<Void>)>('signal');
  signal(ProcessSignal.sigpipe.signalNumber, nullptr);
  final execvp = libc.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
      int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)>('execvp');
  final argv = calloc<Pointer<Utf8>>(arguments.length + 1);
  try {
    for (var i = 0; i < arguments.length; i++) {
      argv[i] = arguments[i].toNativeUtf8();
    }
    execvp(argv[0], argv);
    // execvp returns only on failure. Its diagnostics also stay in stderr's pipe.
    final errno = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            Platform.isMacOS ? '__error' : '__errno_location')()
        .value;
    final message = libc
        .lookupFunction<Pointer<Utf8> Function(Int32),
            Pointer<Utf8> Function(int)>('strerror')(errno)
        .toDartString();
    stderr.writeln('tina: ${arguments.first}: $message');
    exitCode = errno == 2 ? 127 : 126;
  } finally {
    for (var i = 0; i < arguments.length; i++) {
      calloc.free(argv[i]);
    }
    calloc.free(argv);
  }
}

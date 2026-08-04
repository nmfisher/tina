import '../ansi_capable.dart';
import '../stdio.dart';
import 'ansi_backend.dart';
import 'terminal_backend.dart';

/// Function type for creating a [TerminalBackend].
///
/// Consumers can supply a custom factory to [Screen.withBackend] or pass
/// one to [Screen] via the `backendFactory` parameter.
typedef BackendFactory = TerminalBackend Function({
  required Stdio io,
  required AnsiCapable ansi,
});

/// Create the default ANSI backend.
TerminalBackend createAnsiBackend({
  required Stdio io,
  required AnsiCapable ansi,
}) =>
    AnsiBackend(io: io, ansi: ansi);

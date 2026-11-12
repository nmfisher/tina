/// The platform seam the console's ANSI path reads: environment lookups,
/// stdout ANSI capability and debug-trace file appends.
///
/// Conditionally imported (the persistence-seam pattern): the `dart:io`
/// variant is the native behavior, byte-for-byte; the unsupported variant
/// resolves under the wasm compilation, where `dart:io` does not exist —
/// there the environment is empty (the composition root passes what the
/// guest needs explicitly), ANSI stays optimistic (the host owns a real
/// terminal), and debug trace writes are dropped (the host owns the
/// filesystem; the guest has no trace-file contract).
library;

export 'platform_env_unsupported.dart' if (dart.library.io) 'platform_env_io.dart';

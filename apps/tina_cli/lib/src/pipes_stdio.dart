/// The headless engine's stdio: where the pipes protocol's bytes go.
/// Native: the process's stdin/stdout and SIGINT. A wasm composition
/// root passes its own [input]/[emit] into `runSessionPipes` and no
/// signal watch exists — the client's `shutdown` is the interrupt.
library;

import 'dart:async';

import 'pipes_stdio_unsupported.dart' if (dart.library.io) 'pipes_stdio_io.dart';

/// The default inbound stream (the process's stdin natively).
Stream<List<int>>? defaultPipesInput() => nativePipesInput();

/// Writes one line to the protocol's outbound sink.
void defaultPipesEmit(String line) => nativePipesEmit(line);

/// Whether interrupts can be watched on this platform.
bool get canWatchInterrupt => nativeCanWatchInterrupt;

/// The interrupt stream; empty when [canWatchInterrupt] is false.
Stream<void> interruptStream() => nativeInterruptStream();

import 'dart:async';

Stream<List<int>>? nativePipesInput() => null;

void nativePipesEmit(String line) =>
    throw UnsupportedError('a wasm composition root must supply the emit');

bool get nativeCanWatchInterrupt => false;

Stream<void> nativeInterruptStream() => const Stream.empty();

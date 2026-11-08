import 'dart:async';
import 'dart:io';

Stream<List<int>>? nativePipesInput() => stdin;

void nativePipesEmit(String line) => stdout.writeln(line);

bool get nativeCanWatchInterrupt => true;

Stream<void> nativeInterruptStream() =>
    ProcessSignal.sigint.watch().map((_) {});

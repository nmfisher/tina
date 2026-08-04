import 'dart:async';

import 'package:tina_console/tina_console.dart';

/// Stdio fake for app-side tests. Mirrors the one in tina_console/test.
class FakeStdio implements Stdio {
  final _controller = StreamController<List<int>>(sync: true);
  final StringBuffer written = StringBuffer();
  int columns = 80;
  bool hasTerminalValue = true;

  void feedBytes(List<int> bytes) => _controller.add(bytes);

  @override
  Stream<List<int>> get stdin => _controller.stream;

  @override
  void write(String s) => written.write(s);

  @override
  int get terminalColumns => columns;

  @override
  bool get hasTerminal => hasTerminalValue;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();

  void close() => _controller.close();
}

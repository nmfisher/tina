import 'dart:async';

import 'package:tina_console/tina_console.dart';

final class Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();

  void feed(String value) => input.add(value.codeUnits);

  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class Panels implements ConsolePanels {
  @override
  Future<void> spawn([String? model]) async {}
  @override
  Future<void> closeFocused() async {}
  @override
  List<String> describe() => [];
}

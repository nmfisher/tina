import 'console_contribution.dart';
import 'package:fuzzy_ranker/fuzzy_ranker.dart';

/// Optional delivery of new input to a busy conversation. UI code has no
/// knowledge of its loop, tools or provider.
abstract interface class ConsoleInputReceiver {
  bool offerInput(String text);
}

/// Read-only delivery state for input already accepted by the session.
/// The workspace combines this with its own queue without knowing the engine.
abstract interface class ConsolePendingInput {
  int get pendingInputCount;
}

/// Optional delivery of commands that their owners allow during a running
/// turn. Null leaves the line on the ordinary queue; a future owns its lifetime.
abstract interface class ConsoleCommandReceiver {
  Future<void>? offerCommand(String text);
}

abstract interface class ConsoleInputHistory {
  Iterable<String> get inputHistory;
}

/// A conversation presented by a frontend. Session construction and execution
/// stay with the application; panel layout has no engine or provider knowledge.
abstract interface class ConsoleSessionView implements ConsoleContribution {
  String get id;
  String get label;
  bool get quitRequested;
  CompletionProvider? get commandCompletion;
  CompletionProvider? get fileCompletion;
  Future<void> submit(String text);
  void cancel();
  void notice(String text);
  void close();
}

abstract interface class ConsolePanels {
  Future<void> spawn([String? model]);
  Future<void> closeFocused();
  List<String> describe();
}

/// Optional UI contribution that owns input routing across several views.
abstract interface class ConsoleWorkspace {
  Future<int> runConsole(ConsoleContext context, ConsoleSessionView initial,
      Future<ConsoleSessionView> Function(String? model) createSession);
  void repaintConsole();
}

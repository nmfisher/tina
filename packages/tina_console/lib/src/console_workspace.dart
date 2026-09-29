import 'console_contribution.dart';
import 'package:fuzzy_ranker/fuzzy_ranker.dart';

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

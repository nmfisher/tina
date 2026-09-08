import 'package:tina_engine/tina_engine.dart';

/// A recording [AgentSink] for tests that care about the semantic event
/// stream, not rendering. Captures every call and never touches a UI type.
class FakeAgentSink implements AgentSink {
  final List<String> texts = [];
  final List<ToolStartEvent> toolStarts = [];
  final List<ToolOutputEvent> toolOutputs = [];
  final List<ToolCompleteEvent> toolCompletes = [];
  final List<({String message, NoticeKind kind})> notices = [];
  int newlines = 0;
  int activityStarts = 0;
  int activityStops = 0;

  @override
  void text(String s) => texts.add(s);

  @override
  void newline() => newlines++;

  @override
  void toolStart(ToolStartEvent event) => toolStarts.add(event);

  @override
  void toolOutput(ToolOutputEvent event) => toolOutputs.add(event);

  @override
  void toolComplete(ToolCompleteEvent event) => toolCompletes.add(event);

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) =>
      notices.add((message: message, kind: kind));

  @override
  void activityStart() => activityStarts++;

  @override
  void activityStop() => activityStops++;
}

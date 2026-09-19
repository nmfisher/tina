import 'package:tina_engine/tina_engine.dart';

/// A recording [AgentSink] for tests that care about the semantic event
/// stream, not rendering. Captures every call and never touches a UI type.
class FakeAgentSink implements AgentSink {
  final List<String> _texts;
  final List<ToolStartEvent> toolStarts = [];
  final List<ToolOutputEvent> toolOutputs = [];
  final List<ToolCompleteEvent> toolCompletes = [];
  final List<({String message, NoticeKind kind})> notices = [];
  int newlines = 0;
  int activityStarts = 0;
  int activityStops = 0;

  /// Creates a sink that records into an optional external [texts] list.
  /// When omitted, the sink owns its own list.
  FakeAgentSink({List<String>? texts}) : _texts = texts ?? [];

  List<String> get texts => _texts;

  @override
  void text(String s) => _texts.add(s);

  @override
  void newline() => newlines++;

  @override
  void toolStart(ToolStartEvent event) => toolStarts.add(event);

  @override
  void toolOutput(ToolOutputEvent event) => toolOutputs.add(event);

  @override
  void toolComplete(ToolCompleteEvent event) => toolCompletes.add(event);

  /// Streamed reasoning, as delivered: one entry per chunk, plus a closing entry
  /// with [complete] set ('' text) when a block ends.
  final List<({String text, bool startsBlock, bool? complete})> reasoningChunks =
      [];

  @override
  void reasoning(String text, {bool startsBlock = false}) =>
      reasoningChunks.add((text: text, startsBlock: startsBlock, complete: null));

  @override
  void reasoningEnd({required bool complete}) =>
      reasoningChunks.add((text: '', startsBlock: false, complete: complete));

  /// The reasoning text seen so far, block boundaries dropped.
  String get reasoningText => reasoningChunks.map((c) => c.text).join();

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) =>
      notices.add((message: message, kind: kind));

  @override
  void activityStart() => activityStarts++;

  @override
  void activityStop() => activityStops++;
}

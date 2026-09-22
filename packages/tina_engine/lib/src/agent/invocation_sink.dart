import 'run_lifecycle.dart';
import '../runtime/invocation.dart';
import '../tools/tool.dart';
import 'agent_sink.dart';

/// Captures the originating invocation for every delivery, including callbacks
/// that arrive after cancellation. Observers/audit remain outside this buffer.
class InvocationSink implements AgentSink, RunLifecycleSink {
  final AgentSink target;
  final Invocation? invocation;
  InvocationSink(this.target, [this.invocation]);
  void _send(void Function() send, [int size = 1]) {
    final call = invocation ?? InvocationContext.current?.invocation;
    if (call == null) {
      send();
    } else {
      call.output(send, size: size);
    }
  }

  @override
  void runStarted(Object id) {
    final sink = target;
    if (sink is RunLifecycleSink) (sink as RunLifecycleSink).runStarted(id);
  }

  @override
  void runCompleted(Object id) {
    final sink = target;
    if (sink is RunLifecycleSink) (sink as RunLifecycleSink).runCompleted(id);
  }

  @override
  void text(String s) => _send(() => target.text(s), s.length);
  @override
  void newline() => _send(target.newline);
  @override
  void reasoning(String text, {bool startsBlock = false}) => _send(
      () => target.reasoning(text, startsBlock: startsBlock), text.length);
  @override
  void reasoningEnd({required bool complete}) =>
      _send(() => target.reasoningEnd(complete: complete));
  @override
  void toolStart(ToolStartEvent e) => _send(() => target.toolStart(e));
  @override
  void toolOutput(ToolOutputEvent e) =>
      _send(() => target.toolOutput(e), e.chunk.length);
  @override
  void toolComplete(ToolCompleteEvent e) =>
      _send(() => target.toolComplete(e), e.result.length);
  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) =>
      _send(() => target.notice(message, kind: kind), message.length);
  @override
  void activityStart() => _send(target.activityStart);
  @override
  void activityStop() => _send(target.activityStop);
}

import '../tools/tool.dart';
import 'agent_event_bus.dart';
import 'agent_sink.dart';

/// An [AgentSink] for a sub-agent. It does NOT write the main chat or drive a
/// spinner — instead it forwards every payload-carrying call onto a per-job
/// [AgentEventBus] as a [JobAgentEvent] tagged with this job's id/label. The TUI
/// subscribes to the scheduler's merged stream and renders one compact
/// `«{label}: → …»` line per job. The forward-only methods ([newline],
/// [activityStart], [activityStop]) are no-ops: a sub-agent's prose/activity is
/// telemetry, not main-chat output.
///
/// This keeps a single progress channel for both await-driven and (future)
/// detached jobs, and lets the sub-agent reuse the unchanged [Agent] loop.
class SubAgentSink implements AgentSink {
  final String jobId;
  final String label;
  final AgentEventBus bus;

  SubAgentSink({required this.jobId, required this.label, required this.bus});

  void _emit(AgentEvent event) => bus.emit(JobAgentEvent(jobId, label, event));

  @override
  void text(String s) => _emit(TextAgentEvent(s));

  @override
  void newline() {}

  @override
  void toolStart(ToolStartEvent event) => _emit(ToolAgentEvent(event));

  @override
  void toolOutput(ToolOutputEvent event) => _emit(ToolAgentEvent(event));

  @override
  void toolComplete(ToolCompleteEvent event) => _emit(ToolAgentEvent(event));

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) =>
      _emit(NoticeAgentEvent(message, kind));

  @override
  void activityStart() {}

  @override
  void activityStop() {}
}

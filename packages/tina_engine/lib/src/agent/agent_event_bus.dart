import 'dart:async';

import '../tools/tool.dart';
import 'agent_sink.dart';

/// One item the agent emitted: a tool lifecycle event, streamed prose, or a
/// notice. Carried by [AgentEventBus] so non-rendering consumers — logging,
/// telemetry, an orchestrator watching its sub-agents — can observe a turn
/// without each being wired as an [AgentSink] and without bloating the
/// [Agent] constructor.
///
/// The bus carries the full event set (tool lifecycle + prose + notices), so a
/// logger can reconstruct a whole turn; a consumer that only wants tools narrows
/// the stream with `bus.events.where((e) => e is ToolAgentEvent)`.
sealed class AgentEvent {
  const AgentEvent();
}

/// A tool lifecycle event — [ToolStartEvent], [ToolOutputEvent], or
/// [ToolCompleteEvent]. Wraps the [ToolEvent] payload already carried by the
/// [AgentSink] tool methods, so the bus adds no new payload shape.
class ToolAgentEvent extends AgentEvent {
  final ToolEvent event;
  const ToolAgentEvent(this.event);
}

/// Streamed model prose (an assistant text delta).
class TextAgentEvent extends AgentEvent {
  final String text;
  const TextAgentEvent(this.text);
}

/// A status/notice line (`[cancelled]`, budget, a stream error, …) with its
/// [kind].
class NoticeAgentEvent extends AgentEvent {
  final String message;
  final NoticeKind kind;
  const NoticeAgentEvent(this.message, this.kind);
}

/// An [AgentEvent] tagged with the sub-agent job that emitted it, so the UI can
/// render one `«label: → …»` progress line per job. Wraps any event
/// non-invasively — the wrapped event keeps its original type, so a consumer
/// can filter `bus.events.where((e) => e is JobAgentEvent)` and then inspect
/// `.event`.
class JobAgentEvent extends AgentEvent {
  final String jobId;
  final String label;
  final AgentEvent event;
  const JobAgentEvent(this.jobId, this.label, this.event);
}

/// Broadcasts [AgentEvent]s to any number of stream subscribers.
///
/// Sits *behind* the [AgentSink] contract: a [BusSink] forwards each sink call
/// to a real rendering sink and also emits the matching [AgentEvent] here. The
/// agent layer is unchanged — only the host's sink wiring decides whether to
/// wrap a sink in a [BusSink]. Non-rendering consumers then subscribe to
/// [events] with no dependency on any UI type.
class AgentEventBus {
  final StreamController<AgentEvent> _controller =
      StreamController<AgentEvent>.broadcast();

  /// A broadcast stream of every [AgentEvent] emitted on this bus. Late
  /// subscribers see only events emitted after they subscribe.
  Stream<AgentEvent> get events => _controller.stream;

  /// Emit [event] to all current subscribers. A no-op once [dispose]d.
  void emit(AgentEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  /// Close the bus. Active subscriptions end; further [emit] calls are no-ops.
  void dispose() => _controller.close();
}

/// An [AgentSink] that forwards every call to [inner] (the real rendering sink)
/// and, for the calls that carry an [AgentEvent], also emits it on [bus].
///
/// Composes with any inner sink, so it works identically whether the agent is
/// the main agent, a tool-strip-composing sink, or a sub-agent. The forward-only
/// methods ([newline], [activityStart], [activityStop]) reach [inner] but emit
/// nothing — the bus carries tool/text/notice events, not activity signals.
class BusSink implements AgentSink {
  final AgentSink inner;
  final AgentEventBus bus;

  BusSink(this.inner, this.bus);

  @override
  void text(String s) {
    inner.text(s);
    bus.emit(TextAgentEvent(s));
  }

  @override
  void newline() => inner.newline();

  @override
  void toolStart(ToolStartEvent event) {
    inner.toolStart(event);
    bus.emit(ToolAgentEvent(event));
  }

  @override
  void toolOutput(ToolOutputEvent event) {
    inner.toolOutput(event);
    bus.emit(ToolAgentEvent(event));
  }

  @override
  void toolComplete(ToolCompleteEvent event) {
    inner.toolComplete(event);
    bus.emit(ToolAgentEvent(event));
  }

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {
    inner.notice(message, kind: kind);
    bus.emit(NoticeAgentEvent(message, kind));
  }

  @override
  void activityStart() => inner.activityStart();

  @override
  void activityStop() => inner.activityStop();
}

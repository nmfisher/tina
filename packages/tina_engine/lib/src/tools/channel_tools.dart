import 'dart:async';

import '../agent/sub_agent_scheduler.dart';
import 'tool.dart';

/// The orchestrator's sub-agent channel surface — the async counterpart to
/// [DelegateTool]'s await. A *channel* is a persistent sub-agent conversation
/// you address by id: `send` appends a turn (non-blocking), `receive` polls the
/// reply, `close` ends it. Each tool talks to the [SubAgentScheduler] the way
/// `delegate` does; channels are scoped to the originating conversation.
///
/// `receive` (not `read`) avoids clashing with the file `read` tool.
///
/// Interleaving is automatic: because `send` returns at once, the orchestrator
/// can `send` to A then B in one turn (both run concurrently, detached) and
/// `receive` either in a later turn. One in-flight turn per channel.

/// Sends a message to a sub-agent channel and returns immediately.
///
/// - If [target] is an existing channel id, appends [text] to that channel's
///   conversation and re-runs it (the channel must be idle).
/// - If [target] is an agent name, opens a new channel with [text] as its first
///   task.
///
/// Either way the channel id is returned; collect the reply with `receive`.
class SendTool implements Tool {
  final AgentToolContext ctx;
  SendTool(this.ctx);

  SubAgentScheduler get scheduler => ctx.scheduler;

  @override
  ToolSchema get schema => ToolSchema(
        name: 'send',
        description: 'Send a message to a sub-agent and return its channel id '
            'immediately (does NOT wait). If `target` is an existing channel '
            'id, appends to that conversation (the channel must be idle); if '
            'it\'s an agent name, opens a new channel with `text` as the first '
            'task. Get the reply later with `receive`. One in-flight turn per '
            'channel.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'target': {
              'type': 'string',
              'description': 'A channel id (to continue) or an agent name (to '
                  'open a new channel).',
            },
            'text': {
              'type': 'string',
              'description': 'The message / task for the sub-agent.',
            },
          },
          'required': ['target', 'text'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final target = (input['target'] as String?) ?? '';
    final text = (input['text'] as String?) ?? '';
    if (target.isEmpty) return ToolResult.error('send: `target` is required.');
    if (text.isEmpty) return ToolResult.error('send: `text` is required.');

    // Existing channel?
    final job =
        scheduler.jobById(target, conversation: ctx.originConversationId);
    if (job != null) {
      final err = scheduler.send(job, text);
      if (err != null) return ToolResult.error('send: $err');
      return ToolResult(
          'Sent to channel ${job.id} ${job.label}. Get its reply with `receive`.');
    }

    // Otherwise treat `target` as an agent name and open a new channel.
    final spec = ctx.pipeline.role(target);
    if (spec == null) {
      return ToolResult.error(
          'send: unknown channel id or agent "$target".');
    }
    final newJob = scheduler.spawn(
      target: spec,
      task: text,
      parentReference: ctx.parentReference,
      parentPolicy: ctx.parentPolicy,
      originConversationId: ctx.originConversationId,
      depth: ctx.depth,
    );
    return ToolResult(
        'Opened channel ${newJob.id} ${spec.name}. Get its reply with `receive`.');
  }
}

/// Receives a channel's latest reply by id. If the latest turn is still running,
/// reports its status (poll again). No mutation — the orchestrator learns a
/// channel's state only by calling this.
class ReceiveTool implements Tool {
  final SubAgentScheduler scheduler;
  final String originConversationId;

  ReceiveTool(this.scheduler, {required this.originConversationId});

  @override
  ToolSchema get schema => ToolSchema(
        name: 'receive',
        description: 'Get a sub-agent channel\'s latest reply by id. If the '
            'turn is still running, reports its status — poll again. Open '
            'channels with `send`.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final id = (input['id'] as String?) ?? '';
    final job = scheduler.jobById(id, conversation: originConversationId);
    if (job == null) {
      return ToolResult.error('receive: unknown channel id "$id".');
    }
    return ToolResult(scheduler.read(job));
  }
}

/// Closes a channel by id: cancels any in-flight turn and drops it from the
/// registry.
class CloseTool implements Tool {
  final SubAgentScheduler scheduler;
  final String originConversationId;

  CloseTool(this.scheduler, {required this.originConversationId});

  @override
  ToolSchema get schema => ToolSchema(
        name: 'close',
        description: 'Close a sub-agent channel by id. Cancels any in-flight '
            'turn and drops it from the registry.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final id = (input['id'] as String?) ?? '';
    final job = scheduler.jobById(id, conversation: originConversationId);
    if (job == null) {
      return ToolResult.error('close: unknown channel id "$id".');
    }
    await scheduler.close(job);
    return ToolResult('Closed channel $id.');
  }
}

/// Returns a registry with the three channel tools appended, configured for a
/// parent agent by [ctx]. Receive/Close take only the scheduler + conversation
/// they use; Send takes the full context (it can open new channels).
ToolRegistry withChannelTools(ToolRegistry base, AgentToolContext ctx) {
  final scheduler = ctx.scheduler;
  final conversationId = ctx.originConversationId;
  return ToolRegistry([
    ...base.all,
    SendTool(ctx),
    ReceiveTool(scheduler, originConversationId: conversationId),
    CloseTool(scheduler, originConversationId: conversationId),
  ]);
}

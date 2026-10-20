import 'dart:async';
import 'package:tina_activity/tina_activity.dart';
import 'package:classification/plugin.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'package:tina_tasks/tina_tasks.dart';

/// Public data adapters for attachment snapshots. Feature policy, persistence
/// and mutable state stay in their plugins. Never serialize a configuration
/// document, provider, MCP environment/header values or executable callback.
SnapshotFeature? snapshotFeatureFor(AgentPlugin plugin) {
  if (plugin is ActivityPlugin) {
    return SnapshotFeature(
      () => {'print_transcript': plugin.printTranscript},
      historyMetadata: plugin.historyMetadata,
    );
  }
  if (plugin is ChatPlugin) {
    final chat = plugin.observation;
    return SnapshotFeature(
      () => {
        ...chat.events.snapshot,
        'token_cap': chat.tokenCap,
        'session_tokens': chat.sessionTokens,
        'estimated_tokens': chat.sessionEstimatedTokens,
        'session_id': chat.sessionId,
        'show_session_id': chat.showSessionId,
        'terminal_alerts_enabled': chat.terminalAlertsEnabled,
      },
      listen: chat.events.listenChanges,
      historyMetadata: plugin.historyMetadata,
    );
  }
  if (plugin is ApprovalsPlugin) {
    return SnapshotFeature(
      () => {
        'pending': [
          for (final request in plugin.pending)
            {
              'id': request.id,
              'kind': request.kind.name,
              'operation': request.operation,
              'target': request.target,
              'reason': request.reason,
              'details': request.details,
            },
        ],
      },
      listen: plugin.listenPending,
    );
  }
  if (plugin is ModePolicySource) {
    final mode = (plugin as ModePolicySource).modePolicy.observation;
    return SnapshotFeature(
      () => {'mode': mode.mode.name},
      listen: (changed) => mode.listen((_) => changed()),
    );
  }
  if (plugin is PlansPlugin) {
    final plans = plugin.observation;
    return SnapshotFeature(
      () => {
        'approval': plans.state.approval.name,
        'items': [for (final item in plans.state.items) _plan(item)],
      },
      listen: plans.listen,
    );
  }
  if (plugin is TasksPlugin) {
    final tasks = plugin.observation;
    return SnapshotFeature(
      () => {
        'items': [
          for (final item in tasks.state.items)
            {
              'id': item.id,
              'text': item.text,
              'state': item.state,
              if (item.summary.isNotEmpty) 'summary': item.summary,
            },
        ],
      },
      listen: tasks.listen,
    );
  }
  if (plugin is ContextPlugin) {
    final context = plugin.observation;
    // The full accepted context is already in the log's plugin-state entries.
    // Its revision/position identify it without copying every message per token.
    return SnapshotFeature(
      () => {
        'revision': context.workingContext.revision,
        'through_seq': context.workingContext.throughSeq,
        'message_count': context.workingContext.messages.length,
        'budget_tokens': context.budgetTokens,
        'input_tokens': context.budgetUsage?.inputTokens,
        'response_reserve_tokens': context.budgetUsage?.responseReserveTokens,
        'file_status': context.fileStatus,
        'last_edit_tokens_saved': context.latestEditTokensSaved,
        'include_pending_turn': context.includePendingTurn,
        'usage_budget_tokens': context.budgetUsage?.budgetTokens,
        'mirror_path': context.mirrorPath,
        'last_edit_receipt': context.lastEditReceipt == null
            ? null
            : {
                'status': context.lastEditReceipt!.status.name,
                'message': context.lastEditReceipt!.message,
              },
      },
    );
  }
  if (plugin is ClassificationPlugin) {
    final classification = plugin.observation;
    return SnapshotFeature(
      () => {
        'phase': classification.status.phase.name,
        'input_id': classification.status.inputId,
        'result': classification.status.result?.toJson(),
        'reason': classification.status.reason,
        'trace_revision': classification.trace.revision,
        'exchanges': [
          for (final e in classification.trace.exchanges)
            {
              'id': e.id,
              'parent_id': e.parentId,
              'phase': e.phase.name,
              'pending': e.pending,
              'title': e.title,
              'input_id': e.inputId,
              'classifier_id': e.classifierId,
              'classifier_name': e.classifierName,
              'input_text': e.inputText,
              'trigger': e.trigger,
              'request': e.request,
              'response': e.response,
              'error': e.error,
              'questions': e.questions,
              'answers': e.answers,
              'outcome': e.outcome?.label,
              'unclear': e.outcome?.unclear,
              'started': e.started.toUtc().toIso8601String(),
              'elapsed_ms': e.elapsed?.inMilliseconds,
            },
        ],
      },
      listen: classification.listen,
    );
  }
  if (plugin is SessionControlsPlugin) {
    final controls = plugin.observation;
    return SnapshotFeature(
      () => {
        'model': controls.currentModel,
        'recent_models': controls.recentModels,
        'models': controls.catalog.models,
        'provider_names': controls.catalog.providerNames,
        'model_names': controls.catalog.modelNames,
      },
    );
  }
  if (plugin is UpdateStatusSource) {
    final updates = plugin as UpdateStatusSource;
    return SnapshotFeature(
      () => {
        'version': updates.currentVersion,
        'phase': updates.status.phase.name,
        'tag': updates.status.tag,
        'reason': updates.status.reason,
        'until': updates.status.until?.toUtc().toIso8601String(),
      },
      listen: _watch(updates.changes),
    );
  }
  if (plugin is McpPlugin) {
    final management = plugin.management;
    return SnapshotFeature(
      () => {
        'server_status': plugin.serverStatus,
        'servers': [
          for (final server in management?.servers ?? <McpServerConfig>[])
            {
              'name': server.name, 'enabled': server.enabled,
              // Arguments, environment, URLs and headers can contain credentials.
              'transport': server.url == null ? 'stdio' : 'http',
            },
        ],
      },
      listen: management == null ? null : _watch(management.changes),
    );
  }
  return null;
}

Map<String, Object?> _plan(PlanEntryItem item) => {
  'text': item.text,
  'state': item.state,
  'summary': item.summary,
  if (item.children.isNotEmpty)
    'children': [for (final child in item.children) _plan(child)],
};

void Function() Function(void Function()) _watch<T>(Stream<T> changes) =>
    (changed) {
      final subscription = changes.listen((_) => changed());
      return () => unawaited(subscription.cancel());
    };

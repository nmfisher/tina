// Public surface of the application layer (A06). Root code imports this
// library — never `package:tina_app/src/...`. Exports cover exactly the
// application modules the frontend and CLI consume; package-internal
// helpers stay implicit.
library;

export 'src/commands/command_capabilities.dart';
export 'src/commands/command_context.dart';
export 'src/commands/command_registry.dart';
export 'src/commands/session_export.dart';
export 'src/composition/agent_composition.dart';
export 'src/composition/app_composition.dart';
export 'src/composition/live_quotas.dart';
export 'src/composition/edit_verifier.dart';
export 'src/composition/execution_profile.dart';
export 'src/composition/workspace_services.dart';
export 'src/composition/provider_resolution.dart';
export 'src/composition/runtime_plugins.dart';
export 'src/config/runtime_config.dart';
export 'src/config/startup_options.dart';
export 'src/execution/background_job_supervisor.dart';
export 'src/execution/project_background_jobs.dart';
export 'src/execution/turn_executor.dart';
export 'src/execution/input_routes.dart';
export 'src/persistence/session_restore.dart';
export 'src/platform/environment.dart';
export 'src/project/gitignore_guard.dart';
export 'src/project/project_trust.dart';
export 'src/regions/region_registry.dart';
export 'src/session/conversation.dart';
export 'src/session/conversation_selection.dart';
export 'src/session/conversation_operations.dart';
export 'src/session/selection_presenter.dart';
export 'src/session/session_manager.dart';
export 'src/summaries/allocations_store.dart';
export 'src/summaries/summary_index.dart';
export 'src/workflows/default_workflow.dart';
export 'src/workflows/headless_interviewer.dart';
export 'src/workflows/pipeline_commands.dart';
export 'src/workflows/pipeline_runner.dart';
export 'src/workflows/workflow_names.dart';
export 'src/workflows/workflow_supervisor.dart';
// Exploration lives in the classifier package; these shared exports keep
// `package:tina_app/tina_app.dart` the single public surface for the
// structured-judgment workflow the app composes.
export 'package:classifier/exploration.dart';
export 'package:classifier/judgments.dart';
export 'package:classifier/typesafe_classifier.dart';

export 'src/exploration/repository_evidence.dart';
export 'src/exploration/explore_project_tool.dart';
export 'src/exploration/metered_judgment_service.dart';
export 'src/exploration/file_exploration_cache.dart';

export 'src/composition/project_classification.dart';
export 'src/classification/index_options.dart';

export 'src/execution/input_status.dart';
export 'src/execution/git_input.dart';
export 'src/classification/git_classifier.dart';
export 'src/execution/intent_input.dart';
export 'src/classification/intent_classifier.dart';
export 'src/execution/token_status.dart';
export 'src/execution/index_progress_status.dart';

export 'src/execution/interrupts.dart';
export 'src/classification/rules.dart';
export 'src/plans/plan_plugin.dart';

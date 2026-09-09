// Public surface of the application layer (A06). Root code imports this
// library — never `package:tina_app/src/...`. Exports cover exactly the
// application modules the frontend and CLI consume; package-internal
// helpers stay implicit.
library;

export 'src/commands/command_capabilities.dart';
export 'src/commands/command_context.dart';
export 'src/commands/session_export.dart';
export 'src/composition/agent_composition.dart';
export 'src/composition/app_composition.dart';
export 'src/composition/edit_verifier.dart';
export 'src/composition/project_services.dart';
export 'src/composition/provider_resolution.dart';
export 'src/config/environment_options.dart';
export 'src/config/runtime_config.dart';
export 'src/config/startup_options.dart';
export 'src/environment/environment_index.dart';
export 'src/environment/environment_tool_stage.dart';
export 'src/environment/environment_record.dart';
export 'src/execution/background_job_supervisor.dart';
export 'src/execution/project_background_jobs.dart';
export 'src/execution/turn_executor.dart';
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

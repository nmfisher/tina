import 'package:tina_app/src/environment/environment_repository.dart';

class EnvironmentInspection {
  final EnvironmentRepository repository;
  EnvironmentInspection({required this.repository});
  EnvironmentStatus status() {
    final snapshot = repository.inspect();
    return EnvironmentStatus(
      recordPresent: snapshot.recordPresent,
      staleReason: snapshot.staleReason,
    );
  }
}

/// Prepares work for the main conversation and verifies its record update.
/// This service never creates an agent, provider, or scout fleet.
class EnvironmentIndex extends EnvironmentInspection {
  EnvironmentIndex({required super.repository});

  String taskPrompt() {
    final current = status();
    final reason = !current.recordPresent
        ? 'No .tina/ENVIRONMENT.md exists yet.'
        : 'Re-verify .tina/ENVIRONMENT.md${current.staleReason == null ? '' : ': ${current.staleReason}'}.';
    return '$reason\n\n$_task';
  }

  /// Capture at turn start, including when the request waited in the queue.
  EnvironmentSnapshot beginVerification() =>
      repository.inspect(captureRecord: true);

  bool finishVerification(
    EnvironmentSnapshot before, {
    required bool completed,
  }) {
    if (!completed || !repository.advanced(before)) return false;
    repository.record();
    return true;
  }

  static const _task = '''
Establish and record this repository's environment in this conversation. You own the task. Inspect the repository and decide whether delegation is useful, how many sub-agents to spawn, and each one's scope, within the configured limits. Use the normal delegate tool when helpful; there is no required scout count or one-agent-per-folder partition. Coordinate mutating work to avoid conflicts.

Read any existing .tina/ENVIRONMENT.md first. Preserve user-authored intent; change setup/build/test instructions only when your measurements show they need correction, and explain those changes.

- Describe the repository layout and the purpose of its important areas.
- Identify the toolchain and dependency manifests. Run the relevant setup, build, and tests using the normal tools and approval policy.
- Record real outcomes: commands, test counts where available, failures, skipped checks, and blockers. Never invent a baseline or describe an unrun check as passed.
- Check git identity and relevant authentication status. Record references only, never tokens, passwords, or key material. If credentials or other user input are needed, record the required action.
- Write .tina/ENVIRONMENT.md with Layout, Toolchain, Setup, Build, Test, and Auth sections, plus the observed test baseline and a verified-at stamp with the current commit. Keep observations distinct from intended commands.

Finish with a short report of what you ran, what passed or failed, and what needs user action. A prose-only response does not complete this task: the environment record must actually be created or updated.
''';
}

class EnvironmentStatus {
  final bool recordPresent;
  final String? staleReason;
  const EnvironmentStatus({required this.recordPresent, this.staleReason});
  bool get stale => staleReason != null;
}

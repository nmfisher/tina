import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../platform/paths.dart';
import '../runtime/contracts.dart';
import 'atomic_write.dart';
import 'file_system.dart';
import 'mutation_lock.dart';
import 'process_runner.dart';
import 'sandbox.dart';
import 'sandbox_runner.dart';

final _log = Logger('tina.sandbox');

/// Service key under which a composition registers/resolves the project's
/// [ProjectCapabilities].
final ServiceKey<ProjectCapabilities> projectCapabilitiesServiceKey =
    ServiceKey<ProjectCapabilities>('tina.engine.project_capabilities');

/// The project-owned construction results every borrower of a project scope
/// shares: the normalized root, the environment snapshot, the per-project file
/// mutation lock and — when confined — the sandboxed file system, backup store
/// and bash process runner. Built once per scope via [ProjectCapabilities.build];
/// creating another scope never changes these instances or their sandbox
/// configuration.
class ProjectCapabilities {
  /// The normalized, absolute project root all tool paths resolve against.
  final String projectRoot;

  /// The environment snapshot the tools see (unmodifiable).
  final Map<String, String> environment;

  /// Whether file tools are confined to [projectRoot] via [fileSystem] and
  /// [backups]. False leaves the file tools unwired (standalone assembly for
  /// engine consumers without application setup).
  final bool confineFiles;

  /// Whether bash subprocesses run under a sandbox backend (vs pass-through).
  final bool sandboxEnabled;

  /// One shared per-file lock so concurrent agents editing/writing the same
  /// file serialize (AgentQuota allows several to run at once). Owned by the
  /// capabilities so every agent/sub-agent shares it.
  final FileMutationLock mutationLock;

  /// The confined file system rooted at [projectRoot], or null when
  /// [confineFiles] is false.
  final SandboxedFileSystem? fileSystem;

  /// The backup store under `<tinaDir>/backups`, or null when [confineFiles]
  /// is false.
  final BackupStore? backups;

  /// A [SandboxedProcessRunner] when [sandboxEnabled], else the pass-through
  /// [IoProcessRunner].
  final ProcessRunner processRunner;

  /// Builds the capabilities for a project: normalizes/absolutizes the root,
  /// snapshots the environment, creates the shared mutation lock, and — when
  /// [confineFiles] — the sandboxed file system plus backup store under the
  /// same `.tina/backups` dir. Chooses [SandboxedProcessRunner] vs
  /// [IoProcessRunner] by [sandboxEnabled], feeding it extra write-roots from
  /// the `TINA_SANDBOX_ALLOW` env var (colon-separated, empties dropped).
  factory ProjectCapabilities.build({
    required String projectRoot,
    required Map<String, String> env,
    bool confineFiles = true,
    bool sandboxEnabled = true,
    bool sandboxNet = false,
    bool sandboxReadOnly = false,
  }) {
    final root = p.normalize(p.absolute(projectRoot));
    final environment = Map<String, String>.unmodifiable(env);
    // One shared per-file lock so concurrent agents editing/writing the same
    // file serialize (AgentQuota allows several to run at once). Owned by the
    // capabilities so every agent/sub-agent shares it.
    final mutationLock = FileMutationLock();

    final SandboxedFileSystem? fileSystem;
    final BackupStore? backups;
    if (confineFiles) {
      final io = const IoFileSystem();
      fileSystem = SandboxedFileSystem(
        io,
        projectRoot: root,
        tinaDir: tinaDirFromEnv(env),
      );
      backups = BackupStore(
        fs: io,
        storeDir: Directory(p.join(tinaDirFromEnv(env).path, 'backups')),
      );
    } else {
      fileSystem = null;
      backups = null;
    }

    // Confine bash subprocess writes to the project root + temp via
    // sandbox-exec (macOS) or bwrap (Linux) — the structural guard against a
    // destructive command reaching outside the project. Pass-through with a
    // one-time warning where no backend exists. Extra write-roots come from the
    // TINA_SANDBOX_ALLOW env var (colon-separated), then explicit runtime
    // approvals. The runner owns their access policy for all borrowers of the
    // scope; an allow-once invocation uses a separate snapshot.
    final ProcessRunner processRunner;
    if (sandboxEnabled) {
      final extra = (env['TINA_SANDBOX_ALLOW'] ?? '')
          .split(':')
          .where((s) => s.isNotEmpty)
          .toList();
      final runner = SandboxedProcessRunner(
        projectRoot: root,
        extraAllowPaths: extra,
        sandboxNet: sandboxNet,
        sandboxReadOnly: sandboxReadOnly,
      );
      processRunner = runner;
      // Startup diagnostic: name the active backend (or the pass-through
      // reason) once per construction, so a session's log says how bash is
      // boxed.
      _log.info('bash sandbox: ${runner.backendDescription}');
    } else {
      processRunner = const IoProcessRunner();
      _log.info(
          'bash sandbox: pass-through (explicitly disabled via --no-sandbox)');
    }

    return ProjectCapabilities._(
      projectRoot: root,
      environment: environment,
      confineFiles: confineFiles,
      sandboxEnabled: sandboxEnabled,
      mutationLock: mutationLock,
      fileSystem: fileSystem,
      backups: backups,
      processRunner: processRunner,
    );
  }

  ProjectCapabilities._({
    required this.projectRoot,
    required this.environment,
    required this.confineFiles,
    required this.sandboxEnabled,
    required this.mutationLock,
    required this.fileSystem,
    required this.backups,
    required this.processRunner,
  });
}

/// The box model (Stage A): replace prediction with containment.
///
/// Three boxes, one list:
///
/// 1. [Box.readOnly] — read-only in the workspace. Runs inside the enforced
///    read-only profile, never asks.
/// 2. [Box.contained] — writes/network inside an allowed scope. Runs inside
///    an OS sandbox profile fitted to the command family. Silent; reported
///    as one line per command at end of turn.
/// 3. [Box.ask] — needs something no box provides (admin, raw network
///    outside a profile, paths outside mounts). Asks through the existing
///    approval dialog; a remembered pattern lands in the box allowlist
///    ([BoxAllowlist]), a plain versioned file the user can read and edit.
///
/// A profile is data — a [BoxProfileSpec] — never scattered flags, so a
/// profile is a testable artifact and [boxProfileBwrapArguments] maps it to
/// the bwrap argv the OS sandbox runner builds. The sorter
/// (box_sorter.dart) is pure: a request plus its context in, a box plus a
/// suggested profile out. Unknown constructs fall to [Box.ask]; the sorter
/// never guesses in favor of silence.
///
/// Stage A ships this as a parallel decision path behind an opt-in
/// ([permissionBoxesSetting]). The existing classifier/modes stack and its
/// tests are untouched; when the opt-in is off nothing here executes.
library;

import 'package:path/path.dart' as path;
import 'package:tina_settings/tina_settings.dart';

import 'os_sandbox_runner.dart';
import 'sandbox_home.dart' show sandboxPathAliases;
import 'sandbox_layout.dart';

/// Which box a command sorts into.
enum Box {
  /// Box 1: read-only in the workspace — run, never ask.
  readOnly,

  /// Box 2: writes/network inside an allowed scope — run inside a sandbox
  /// profile, report at end of turn.
  contained,

  /// Box 3: needs something no box provides — ask.
  ask;

  String get label => switch (this) {
        Box.readOnly => '1',
        Box.contained => '2',
        Box.ask => '3',
      };
}

/// One sandbox profile: a named containment spec. The four built-ins are
/// const instances; the spec is the data the gate and the tests read.
final class BoxProfileSpec {
  const BoxProfileSpec({
    required this.name,
    required this.summary,
    required this.workspaceWritable,
    required this.tempWritable,
    required this.cacheTargetsWritable,
    required this.network,
  });

  /// One of `scripts`, `build`, `packages`, `default`.
  final String name;

  /// Human words for reports and the design note.
  final String summary;

  /// The workspace is bound read-write (false: bound read-only).
  final bool workspaceWritable;

  /// Private temp scratch (session home / TMPDIR) stays writable.
  final bool tempWritable;

  /// The plan's shared home cache targets (pub/cargo caches) are writable.
  final bool cacheTargetsWritable;

  /// Network is available inside the profile.
  final bool network;

  /// The control flags this profile maps onto on the OS sandbox runner:
  /// read-only enforcement unless the workspace is writable, and network
  /// authorization exactly when the profile has it.
  ({bool readOnly, bool networkAllowed}) get control => (
        readOnly: !workspaceWritable,
        networkAllowed: network,
      );

  @override
  String toString() => name;
}

/// Interpreted scripts: workspace read-only, temp writes, no network.
const boxProfileScripts = BoxProfileSpec(
  name: 'scripts',
  summary: 'workspace read-only, temp writable, no network',
  workspaceWritable: false,
  tempWritable: true,
  cacheTargetsWritable: false,
  network: false,
);

/// Builds and tests: workspace read-write, no network.
const boxProfileBuild = BoxProfileSpec(
  name: 'build',
  summary: 'workspace read-write, caches and temp writable, no network',
  workspaceWritable: true,
  tempWritable: true,
  cacheTargetsWritable: true,
  network: false,
);

/// Package fetches: network plus package cache directories writable.
const boxProfilePackages = BoxProfileSpec(
  name: 'packages',
  summary: 'network, workspace read-write, caches and temp writable',
  workspaceWritable: true,
  tempWritable: true,
  cacheTargetsWritable: true,
  network: true,
);

/// The fallback containment: workspace read-only, no network. What the
/// enforced read-only execution profile already builds.
const boxProfileDefault = BoxProfileSpec(
  name: 'default',
  summary: 'workspace read-only, temp writable, no network',
  workspaceWritable: false,
  tempWritable: true,
  cacheTargetsWritable: false,
  network: false,
);

/// Every named profile, by name.
const boxProfiles = <String, BoxProfileSpec>{
  'scripts': boxProfileScripts,
  'build': boxProfileBuild,
  'packages': boxProfilePackages,
  'default': boxProfileDefault,
};

/// The profile a box-2 decision carries; box 1 implies [boxProfileDefault].
BoxProfileSpec? boxProfileByName(String? name) =>
    name == null ? null : boxProfiles[name];

/// The bwrap argv a profile builds from one plan — the same argument list
/// [OsSandboxRunner] assembles for the control flags the profile maps onto
/// ([BoxProfileSpec.control]). Pure: the plan and host layout in, the argv
/// out, no host probes; callers pass an inspected [SandboxHostLayout].
///
/// Read-only profiles (scripts/default) bind the workspace `--ro-bind`,
/// keep only private scratch writable and mount the plan's other writable
/// paths read-only — exactly the runner's read-only enforcement. Write
/// profiles (build/packages) bind the workspace and the plan's extra
/// writable paths (scratch, session home, shared caches) read-write.
/// `packages` is the only profile without `--unshare-net`.
List<String> boxProfileBwrapArguments({
  required SandboxPlan plan,
  required BoxProfileSpec profile,
  required SandboxHostLayout host,
}) {
  final readOnly = !profile.workspaceWritable;
  final writablePaths = readOnly
      ? [
          if (profile.tempWritable) ...plan.scratchDirectories,
          if (plan.home?.existingPath case final String home) home,
        ]
      : [
          ...plan.extraWritablePaths,
          if (profile.tempWritable) ...plan.scratchDirectories,
        ];
  return buildBwrapArguments(
    host: host,
    workspaceRoot: plan.workspaceRoot,
    tinaDir: plan.tinaDir,
    deniedPaths: plan.deniedPaths,
    writablePaths: sandboxPathAliases(writablePaths),
    readOnlyPaths:
        readOnly ? sandboxPathAliases(plan.extraWritablePaths) : const [],
    readOnlyWorkspace: readOnly,
    isolateNetwork: !profile.network,
    childEnvironment: plan.childEnvironment,
  );
}

/// The Stage A opt-in. A settings key, not a PermissionMode value or a CLI
/// flag: modes are user-cycled and feed the decision pipeline's ceilings
/// and the prompt sections (churn), and a flag cannot be reviewed or
/// persisted per project. A boolean setting is readable live by the tools
/// plugin, reviewable in Settings → Permissions, and defaults to off —
/// every existing test outcome is preserved.
final permissionBoxesSetting = SettingDefinition<bool>(
  id: 'tina/tools/permission_boxes',
  label: 'Box-model permissions (Stage A)',
  description: 'Route commands through the three-box model: read-only '
      'workspace commands and profile-contained commands (scripts, builds, '
      'package fetches) run without asking and are contained by the OS '
      'sandbox; everything else asks once and can be remembered as a glob '
      'pattern in the box allowlist (.tina/box_allowlist, editable). The '
      'existing permission modes and grants keep working alongside.',
  defaultValue: false,
  kind: SettingKind.toggle,
);

/// Where the box allowlist files live. One per project, one global — no
/// session/workspace/global triple.
String boxAllowlistProjectPath(String workspaceRoot) =>
    path.join(workspaceRoot, '.tina', 'box_allowlist');

String boxAllowlistGlobalPath(String home) =>
    path.join(home, '.tina', 'box_allowlist');

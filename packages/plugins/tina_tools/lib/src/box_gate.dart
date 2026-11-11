/// The gate that turns box decisions into silent runs. One seam between
/// the sorter (pure) and the process runner (enforcement): when the
/// opt-in is on, [route] classifies a request and either hands back the
/// exact spawn + control to run it silently (boxes 1 and 2) or returns
/// null so the existing decision pipeline owns the command (box 3, or any
/// case the gate declines — disabled, no backend, a read-only mode
/// ceiling on a writable profile).
///
/// Box 2 runs are reported: one line per command, drained at end of turn
/// (like the existing batched auto-mode decisions). Box 1 is fully silent.
library;

import 'box_allowlist.dart';
import 'box_model.dart';
import 'box_sorter.dart';
import 'capability_envelope.dart';
import 'command_approval_store.dart' show approvalCommandText;
import 'os_sandbox_runner.dart';
import 'permissions.dart';
import 'process_runner.dart';
import 'package:tina_mode/tina_mode.dart' show PermissionAccessOperation;

/// How one request runs under the box model.
final class BoxRouting {
  const BoxRouting._(this.decision, this.spawn, this.control, this.note);

  final BoxDecision decision;
  final ProcessRequest spawn;
  final ProcessControl control;
  final String note;
}

/// Whether [gate] routes, and how.
final class BoxModelGate {
  BoxModelGate({
    required this.plan,
    required this.workspaceRoot,
    this.allowlist,
    bool Function()? enabled,
  }) : _enabled = enabled;

  final SandboxPlan plan;
  final String workspaceRoot;
  final BoxAllowlist? allowlist;
  bool Function()? _enabled;

  /// The opt-in check, consulted per command.
  bool get isActive => _enabled?.call() ?? false;

  /// Replace the enabled check (wiring convenience for hosts that read a
  /// live setting).
  set enabledCheck(bool Function() check) => _enabled = check;

  final List<String> _reports = [];

  /// The end-of-turn batch: one line per silent box-2 run this turn.
  List<String> drainReports() {
    if (_reports.isEmpty) return const [];
    final lines = List<String>.unmodifiable(_reports);
    _reports.clear();
    return lines;
  }

  /// Stores one pattern from a box-3 ask's "always allow this pattern"
  /// answer. The rule names the box/profile the approved run used, so
  /// future matches run silently in it: a read-only-approved run stores
  /// box 1, a network-approved run the packages profile, anything else
  /// the build profile. [global] picks the global allowlist file.
  void rememberPattern(String pattern,
      {bool global = false, bool network = false, bool readOnly = false}) {
    final box = readOnly && !network ? Box.readOnly : Box.contained;
    final profile = network
        ? boxProfilePackages
        : readOnly
            ? null
            : boxProfileBuild;
    allowlist?.remember(pattern, box, profile, global: global);
  }

  /// Classifies [request] and returns how it runs silently, or null when
  /// the existing decision pipeline should own it.
  BoxRouting? route(
    ProcessRequest request,
    ProcessControl? control, {
    required CapabilityEnvelope envelope,
    required bool confined,
    required PermissionMode mode,
  }) {
    if (!isActive) return null;
    // yolo is launch-time authorization: the existing pipeline already
    // runs everything; the box path adds nothing there.
    if (mode == PermissionMode.yolo) return null;
    final decision = sortBox(
      request,
      context: (
        workspaceRoot: workspaceRoot,
        confined: confined,
        networkRequested: control?.networkRequested ?? false,
        readOnlyRequested: control?.readOnlyRequested,
        outsideSandboxRequested: control?.outsideSandboxRequested ?? false,
        declaredReads: List.of(control?.readDirectories ?? const []),
        declaredWrites: List.of(control?.writeDirectories ?? const []),
        certifiedReadOnly: envelope.certifiedReadOnly,
        verifiedReads: [
          for (final access in envelope.verifiedAccesses)
            if (access.operation == PermissionAccessOperation.read)
              access.path,
        ],
        canRead: (path) => plan.canRead(path),
        canWrite: (path) => plan.canWrite(path),
        allowlist: allowlist,
      ),
    );
    if (decision.box == Box.ask) return null;
    if (decision.box == Box.readOnly) {
      return BoxRouting._(
        decision,
        _pinnedSpawn(request, envelope),
        _control(control, readOnly: true, networkAllowed: false),
        'box model: read-only containment',
      );
    }
    final profile = decision.profile!;
    // A writable or networked profile cannot run under the read-only mode
    // ceiling; the existing pipeline refuses it with its own message.
    if (mode == PermissionMode.readOnly && (profile.workspaceWritable || profile.network)) {
      return null;
    }
    if (decision.box == Box.contained) {
      _reports.add(decision.reportLine(approvalCommandText(request)));
      return BoxRouting._(
        decision,
        request,
        _control(control,
            readOnly: profile.control.readOnly,
            networkAllowed: profile.control.networkAllowed),
        'box model: contained (${profile.name} profile)',
      );
    }
    return null;
  }

  /// A certified reader still gets its pinned spawn (resolved executable,
  /// certified arguments) — parity with the existing read-only path.
  ProcessRequest _pinnedSpawn(
      ProcessRequest request, CapabilityEnvelope envelope) {
    final reader = envelope.reader;
    if (reader != null) {
      return (
        command: reader,
        arguments: envelope.certifiedArguments,
        workingDirectory: request.workingDirectory,
        environment: request.environment,
        stdin: request.stdin,
        timeout: request.timeout,
      );
    }
    return envelope.shellReader ?? request;
  }

  /// The normalized control for a silent run: the profile's enforcement
  /// flags, declarations dropped (the sorter already checked every
  /// declared path sits where the profile's mounts contain it), and no
  /// authorization fields carried in from tool input.
  ProcessControl _control(ProcessControl? control,
      {required bool readOnly, required bool networkAllowed}) {
    return (control ?? const ProcessControl()).copyWith(
      readOnly: readOnly,
      networkAllowed: networkAllowed,
      readDirectories: const [],
      writeDirectories: const [],
      outputDirectories: const [],
      clearDirectoryApproval: true,
    );
  }
}

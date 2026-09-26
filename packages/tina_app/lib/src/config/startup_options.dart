import 'package:tina_app/src/project/project_trust.dart';
import 'package:tina_app/src/config/resume_request.dart';
export 'package:tina_app/src/config/resume_request.dart';

/// Default cap on agent turns in goal mode (`--goal`): exit 1 once the loop
/// has run this many turns without an `achieved` verdict. 0 = unlimited.
const int defaultMaxGoalTurns = 25;

/// Root-owned startup actions and execution-mode selection.
class StartupOptions {
  final ResumeRequest resume;
  final bool showHelp;
  final String? models;
  final bool showVersion;
  final String? prompt;

  /// Goal mode (`--goal`): the seeded goal text. Non-null routes the launch
  /// into the goal loop instead of the single-turn `--prompt` runner.
  final String? goal;

  /// Goal-mode turn cap; exit 1 after this many turns without an `achieved`
  /// verdict. 0 = unlimited.
  final int maxGoalTurns;
  final bool listSessions;
  final bool resumePicker;
  final String? workflow;
  final bool verbose;
  final bool initConfig;
  final bool setup;
  final bool? trustOverride;
  final TrustDefault trustDefault;
  final bool forceLock;

  /// `--yolo` posture. Startup-facing twin of [RuntimeConfig.yolo]: the
  /// headless host uses it to drop refusal hints that would point at a flag
  /// already in effect.
  final bool yolo;
  const StartupOptions({
    this.resume = const ResumeRequest(),
    this.showHelp = false,
    this.models,
    this.showVersion = false,
    this.prompt,
    this.goal,
    this.maxGoalTurns = defaultMaxGoalTurns,
    this.listSessions = false,
    this.resumePicker = false,
    this.workflow,
    this.verbose = false,
    this.initConfig = false,
    this.setup = false,
    this.trustOverride,
    this.trustDefault = TrustDefault.ask,
    this.forceLock = false,
    this.yolo = false,
  });

  /// Goal mode is its own headless paradigm: seed a goal, loop turns until the
  /// judge rules it achieved. bin/ routes on this before the [prompt] /
  /// [workflow] branches.
  bool get goalMode => goal != null;

  bool get nonInteractive => prompt != null || workflow != null || goalMode;
}

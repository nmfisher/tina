import 'package:tina_app/src/project/project_trust.dart';
import 'package:tina_app/src/config/resume_request.dart';
export 'package:tina_app/src/config/resume_request.dart';

/// Root-owned startup actions and execution-mode selection.
class StartupOptions {
  final ResumeRequest resume;
  final bool showHelp;
  final String? models;
  final bool showVersion;
  final String? prompt;
  final bool listSessions;
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
    this.listSessions = false,
    this.workflow,
    this.verbose = false,
    this.initConfig = false,
    this.setup = false,
    this.trustOverride,
    this.trustDefault = TrustDefault.ask,
    this.forceLock = false,
    this.yolo = false,
  });
  bool get nonInteractive => prompt != null || workflow != null;
}

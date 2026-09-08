import '../project/project_trust.dart';
import 'resume_request.dart';
export 'resume_request.dart';

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
  });
  bool get nonInteractive => prompt != null || workflow != null;
}

import 'dart:io';

import 'package:path/path.dart' as p;

/// Runtime-owned prompt inputs. Sources are read afresh on every resolution;
/// the project root and trust decision are captured once at composition.
class PromptContext {
  final String projectRoot;
  final bool loadProjectContext;
  final String? Function()? projectEnvironmentSource;
  final String? Function()? repoSummarySource;

  PromptContext({
    String? projectRoot,
    this.loadProjectContext = true,
    this.projectEnvironmentSource,
    this.repoSummarySource,
  }) : projectRoot =
            p.normalize(p.absolute(projectRoot ?? Directory.current.path));
}

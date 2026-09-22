import 'dart:io';

import 'package:path/path.dart' as p;

/// Runtime-owned prompt inputs. Sources are read afresh on every resolution;
/// the project root and trust decision are captured once at composition.
class PromptContext {
  final String workspaceRoot;
  final bool loadWorkspaceContext;
  final String? Function()? repoSummarySource;

  PromptContext({
    String? workspaceRoot,
    this.loadWorkspaceContext = true,
    this.repoSummarySource,
  }) : workspaceRoot =
            p.normalize(p.absolute(workspaceRoot ?? Directory.current.path));
}

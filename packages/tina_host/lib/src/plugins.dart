/// The plugin the host contributes: the session's context in one prompt
/// section. The loop owns the join (header, then one section per plugin);
/// this returns one section, never a prompt.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart' show PermissionMode;

/// One plugin: id `host`, whose `systemSection` tells the model where the
/// session works and what the mode currently allows. The section is built
/// per turn, so a mode switch mid-session is described on the next turn.
final class HostPlugin extends AgentPlugin {
  const HostPlugin({
    this.id = 'host',
    this.order = 0,
    required this.workingDirectory,
    required this.mode,
  });

  @override
  final String id;

  /// First among equals: the host's section precedes any sibling plugin's.
  @override
  final int order;

  /// The directory the session works in.
  final String workingDirectory;

  /// Read by the loop each turn — the same live value the sandbox reads
  /// per call, so the prompt and the enforcement stay in step.
  final PermissionMode mode;

  @override
  String systemSection(Context c) => 'Working directory: $workingDirectory. '
      'Mode: ${mode == PermissionMode.readOnly ? 'read-only' : 'normal'} — '
      '${mode == PermissionMode.readOnly ? 'writes are refused; reads run'
          : 'reads run; writes inside the working directory run; writes '
              'outside it are refused unless approved'}.';
}

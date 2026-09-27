/// The plugin the host contributes: the session's context in one prompt
/// section. The loop owns the join (header, then one section per plugin);
/// this returns one section, never a prompt.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart' show PermissionMode;

/// One plugin: id `host`, whose `systemSection` tells the model where the
/// session works and what the mode currently allows.
///
/// The mode is read through [modeOf] — a getter over the live sandbox, not
/// a value copied at start — so the loop, which calls `systemSection` once
/// per turn, always describes the mode the next tool call will actually be
/// judged by. Switch the host's mode and the next turn's prompt agrees
/// with the next call's enforcement.
final class HostPlugin extends AgentPlugin {
  HostPlugin({
    this.id = 'host',
    this.order = 0,
    required this.workingDirectory,
    required PermissionMode Function() modeOf,
  }) : _modeOf = modeOf;

  @override
  final String id;

  /// First among equals: the host's section precedes any sibling's.
  @override
  final int order;

  /// The directory the session works in.
  final String workingDirectory;

  final PermissionMode Function() _modeOf;

  /// The mode as of now.
  PermissionMode get mode => _modeOf();

  @override
  String systemSection(Context c) => sectionFor(_modeOf());

  /// The section for a given mode — the words the model reads.
  String sectionFor(PermissionMode mode) =>
      'Working directory: $workingDirectory. '
      'Mode: ${mode == PermissionMode.readOnly ? 'read-only' : 'normal'} — '
      '${mode == PermissionMode.readOnly
          ? 'writes are refused; reads run'
          : 'reads run; writes inside the working directory run; writes '
              'outside it are refused unless approved'}.';
}

import '../tools/tool.dart';

// ---------------------------------------------------------------------------
// Tool profiles — the fixed set a delegation picks from.
//
// A sub-agent no longer carries its own tool set (there are no roles). The
// parent chooses one of these named profiles when delegating. `read-only` is
// the safe default so research-style sub-agents can't mutate the project;
// `full` adds the file/shell tools an implementer needs.
// ---------------------------------------------------------------------------

/// The fixed set of tool profiles a delegation may grant a sub-agent.
enum ToolProfile {
  /// Source-read-only: read/explore the project, fetch the web, and capture a
  /// directory summary into the sidecar. Cannot write, edit, or run shell
  /// against the project — the safe profile for research/exploration.
  readOnly,

  /// `read-only` plus the mutating tools (write, edit, bash) and web search.
  /// For sub-agents that must change the project or run commands.
  full,
}

/// Resolve a [ToolProfile] from the string a delegation carries (`"read-only"`
/// / `"full"`). Unknown / empty → [ToolProfile.readOnly] (the safe default).
ToolProfile parseToolProfile(String? raw) {
  switch (raw) {
    case 'full':
      return ToolProfile.full;
    default:
      return ToolProfile.readOnly;
  }
}

/// Tool names disabled under `--safe-mode`: every tool that can mutate the
/// filesystem or run an arbitrary shell. Removing these from a registry leaves
/// only read-only tools; the per-profile policy is derived from the same
/// filtered set, so it tracks. `write_summary` writes to the sidecar summaries
/// store, so it is a filesystem-mutating tool and is stripped under read-only
/// mode too.
const Set<String> kSafeModeDisabledTools = {
  'write',
  'edit',
  'bash',
  'write_summary'
};

/// Drop the safe-mode-disabled tools. Called at each registry site when
/// `--safe-mode` is on.
List<Tool> stripForSafeMode(Iterable<Tool> tools) => tools
    .where((t) => !kSafeModeDisabledTools.contains(t.schema.name))
    .toList();

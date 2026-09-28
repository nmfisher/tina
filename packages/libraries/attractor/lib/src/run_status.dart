/// Per-node progress state for a live workflow run. UI-agnostic: consumed by
/// the ASCII renderer (border glyphs in [renderGraph]) and by app-layer views
/// (the TUI run panel's colored status list, the supervisor's live tracking).
enum NodeRunStatus {
  /// Not started yet.
  pending,

  /// In flight (a handler is executing the node — or a parallel branch).
  running,

  /// Completed successfully.
  done,

  /// Completed in failure.
  failed,

  /// The engine skipped the node.
  skipped,
}

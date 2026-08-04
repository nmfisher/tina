import '../agent/agent_event_bus.dart';
import '../agent/agent_sink.dart';
import '../permissions/preview.dart';
import '../permissions/prompt.dart';

/// Styling for [HostInterface.showMessage]. Hosts map these to whatever their
/// frontend supports (terminal colors, log levels, web toasts). A host that has
/// no notion of style renders every value the same.
enum HostMessageStyle { normal, dim, user, warning, error, success }

/// A per-conversation channel between the session layer and whatever frontend
/// is hosting it — a terminal TUI today, a headless runner for `--prompt`, a
/// future web bridge. It is the single seam the session/REPL layer speaks
/// through instead of reaching for terminal types directly.
///
/// Extends [AgentSink] so a [HostInterface] can be handed straight to [Agent]
/// as its sink: the agent keeps speaking only through [AgentSink], unaware of
/// the host. The extra members cover the host-facing operations the session
/// layer needs (status lines, separators, activity signals, permission prompts,
/// lifecycle) that were previously hard-wired to `ChatRegion`/`Spinner`.
///
/// Every method is deliberately declared (no default bodies): a host opts into
/// each operation explicitly, so adding a member surfaces a compile error on
/// every implementor rather than silently inheriting a no-op. A terminal host
/// implements all of them; a headless host implements the cosmetic ones as
/// no-ops.
///
/// The agent is also asked for permission through [askPermission]; since
/// [PermissionAsker] is `Future<PermissionResponse> Function(PermissionPrompt)`,
/// a host is wired as both `sink:` and `asker:` at the composition root.
abstract class HostInterface implements AgentSink {
  /// Broadcast stream of UI-agnostic agent events (text, tool lifecycle,
  /// notices). Observers — a logger, telemetry, a web bridge, a test spy —
  /// subscribe here without depending on any terminal type.
  AgentEventBus get eventBus;

  /// Request permission for a tool call. The host decides how to present the
  /// prompt (an interactive modal, an auto-deny) and returns the decision.
  Future<PermissionResponse> askPermission(PermissionPrompt prompt);

  /// Show a preview before a permission decision. A host that doesn't render
  /// previews implements this as a no-op.
  void showPreview(List<PreviewEntry> preview);

  /// Host-level messaging: slash-command output, status lines, errors.
  void showMessage(String message,
      {HostMessageStyle style = HostMessageStyle.normal});

  /// A visual separator between turns/sections. A host without structure may
  /// implement this as a no-op.
  void showSeparator();

  /// Clear the conversation surface (e.g. `/clear`). A host with no scrollback
  /// to erase implements this as a no-op.
  void clear();

  /// "The agent is working" signal. A TUI drives its spinner; a headless host
  /// no-ops.
  void setActivity(bool active);

  /// "The agent is idle" signal. A TUI idles its spinner; a headless host
  /// no-ops.
  void setIdle(bool active);

  /// Called when this conversation becomes (or stops being) the active one on
  /// screen, so the host can attach/detach its surface. Essential for
  /// multi-session UIs.
  void setActive(bool active);

  /// Forward a terminal resize. A host with no geometry no-ops.
  void handleResize();

  /// Release host-held resources (regions, spinners, the event bus).
  Future<void> dispose();
}

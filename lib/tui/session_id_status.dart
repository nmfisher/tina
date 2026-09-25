import 'dart:async';

import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// The strip view-model for the session indicator.
class SessionIdSnapshot {
  final String sessionId;

  const SessionIdSnapshot(this.sessionId);
}

/// A pull-style [StatusSource] over the session manager: [read] snapshots
/// `sessionManager.activeId` at render time. Unlike the push-style sources
/// (token spend, index progress, version check), it emits no changes of its
/// own — [SessionController.onSessionsChanged] /
/// [onActiveFocusChanged] already call `inputStatus.refresh()` on every
/// session/conversation switch, so the pull repaints for free. A source with
/// a silent `changes` stream would go stale on switch, so it never
/// constructs one.
///
/// Reads null only when the conversation has no recorder (never-persisted
/// sessions, headless hosts) so the strip stays clean there; a recorder's
/// session id is non-nullable and set from construction.
class SessionIdStatusSource implements StatusSource {
  final SessionManager sessionManager;

  const SessionIdStatusSource(this.sessionManager);

  @override
  Object? read(String conversationId) {
    final rec = sessionManager.activeConversation.recorder;
    if (rec == null) return null;
    return SessionIdSnapshot(rec.sessionId);
  }

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

/// Renderer: `session <id>` left-aligned in dim. Session ids are long
/// (`20260925-072154-ab12`), so it's the first left line dropped under width
/// pressure (PriorityStatusLayout drops from the end backward).
class SessionIdStatusRenderer extends Renderer<SessionIdSnapshot> {
  const SessionIdStatusRenderer();

  @override
  List<RenderLine> render(SessionIdSnapshot value, RenderContext context) {
    return [
      RenderLine(
        runs: [
          RenderRun('session ', context.theme.chat.dim),
          RenderRun(value.sessionId, null),
        ],
      ),
    ];
  }
}

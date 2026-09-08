import '../application/conversation_selection.dart';

/// Frontend adapter for a completed application selection.
void presentConversationSelection(ConversationSelection selection) {
  if (!selection.changed) return;
  selection.previous.host.setActive(false);
  selection.next.host.setActive(true);
  if (selection.next.isRunning) {
    selection.next.host.setActivity(true);
  } else {
    selection.next.host.setIdle(true);
  }
}

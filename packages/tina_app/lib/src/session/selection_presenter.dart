import 'conversation_selection.dart';

/// Applies a completed application selection to the conversation hosts.
/// Presentation lives beside the application layer because it touches only
/// the neutral host activity API; frontend callers may supply their own.
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

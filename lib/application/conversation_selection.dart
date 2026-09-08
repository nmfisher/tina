import '../conversation.dart';

/// Selection state returned independently of host presentation.
class ConversationSelection {
  final String sessionId;
  final Conversation previous;
  final Conversation next;
  const ConversationSelection(this.sessionId, this.previous, this.next);
  bool get changed => !identical(previous, next);
}

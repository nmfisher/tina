/// A live, conversation-scoped value supplied by a plugin. The frontend owns
/// rendering and subscribes only while the source remains registered.
abstract interface class StatusSource {
  Object? read(String conversationId);
  Stream<void> get changes;
}

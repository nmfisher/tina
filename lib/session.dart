import 'conversation.dart';

/// A workspace that holds one or more [Conversation]s. The session carries the
/// account context (provider id, API key, base URL); each conversation within
/// it owns its own agent (model + system prompt + tools), permission policy,
/// history, and chat region.
///
/// Today every session has exactly one conversation, but this container is the
/// seam that will let a session grow several — each with differing tools and
/// permissions. The [SessionManager] owns the live set of sessions and routes
/// the active [Conversation] to the screen.
class Session {
  final String id;
  String label;

  /// Account context shared by every conversation in this session.
  final String providerId;
  final String apiKey;
  final String? baseUrl;

  /// Count of unread activity events produced while this session was in the
  /// background. Reset to 0 when the session is switched to (foregrounded).
  /// Drives the background-activity badge in the session bar.
  int unread = 0;

  final Map<String, Conversation> _conversations = {};
  String _activeConversationId;

  Session({
    required this.id,
    required this.label,
    required this.providerId,
    required this.apiKey,
    this.baseUrl,
    required Conversation initialConversation,
  }) : _activeConversationId = initialConversation.id {
    _conversations[initialConversation.id] = initialConversation;
  }

  /// The conversation currently routed to the screen for this session.
  Conversation get activeConversation =>
      _conversations[_activeConversationId]!;

  /// The id of [activeConversation].
  String get activeConversationId => _activeConversationId;

  /// All conversations in this session, in insertion order.
  List<Conversation> get conversations => _conversations.values.toList();

  /// Look up a conversation by id, or null.
  Conversation? conversationById(String id) => _conversations[id];

  int get conversationCount => _conversations.length;

  /// Add a conversation without making it active.
  Conversation addConversation(Conversation c) {
    _conversations[c.id] = c;
    return c;
  }

  /// Make [id] the active conversation. Throws if it isn't a member.
  void setActiveConversation(String id) {
    if (!_conversations.containsKey(id)) {
      throw ArgumentError('Unknown conversation: $id');
    }
    _activeConversationId = id;
  }

  /// Remove a conversation. If it was active, fall back to another member (the
  /// session must always have a conversation; the caller is responsible for not
  /// removing the last one, or for closing the session instead).
  void removeConversation(String id) {
    _conversations.remove(id);
    if (_activeConversationId == id && _conversations.isNotEmpty) {
      _activeConversationId = _conversations.keys.first;
    }
  }

  /// A session is "running" if its active conversation has a turn in flight.
  bool get isRunning => activeConversation.isRunning;
}

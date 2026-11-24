/// Pure presentation logic for the channel pane: the unread tracker,
/// the input composer and the line renderer. No console, no io —
/// deterministic and testable with nothing but value types and a
/// store, which is how the smoke test drives them.
library;

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_console/tina_console.dart'
    show
        CharInput,
        ControlCode,
        ControlKey,
        EditingAction,
        EditingKey,
        EscapeKey,
        InputEvent,
        PasteInput;

/// Tracks per-channel unread counts for one reader. The store is
/// shared; "unread" is a per-reader notion, so the cursor lives here,
/// not in the store. Seed once (the pane opening baseline), refresh on
/// every poll, mark read when the channel is viewed.
final class ChannelUnread {
  final _lastSeen = <String, int>{};

  /// Sets the baseline: everything before the pane existed is read.
  void seed(Iterable<ChannelSummary> channels) {
    for (final channel in channels) {
      _lastSeen[channel.name] = channel.lastMessageId;
    }
  }

  /// Recomputes unread counts from a fresh channel listing.
  Map<String, int> refresh(Iterable<ChannelSummary> channels) {
    final unread = <String, int>{};
    for (final channel in channels) {
      final seen = _lastSeen[channel.name];
      if (seen == null) {
        // A channel first seen after seeding starts fully read unless
        // it has activity; otherwise every pre-existing channel would
        // flash unread on first poll.
        if (channel.lastMessageId > 0) {
          _lastSeen[channel.name] = channel.lastMessageId;
        }
        continue;
      }
      final delta = channel.lastMessageId - seen;
      if (delta > 0) unread[channel.name] = delta;
    }
    return unread;
  }

  /// The reader viewed the channel through [lastId]; the badge clears.
  void markRead(String channel, int lastId) {
    final previous = _lastSeen[channel] ?? 0;
    if (lastId > previous) _lastSeen[channel] = lastId;
  }

  /// The stored cursor, for tests and debugging.
  int cursor(String channel) => _lastSeen[channel] ?? 0;
}

/// One frame of the pane's input line. Null (the line absent) when the
/// pane is browsing rather than composing — the visible focus state.
final class ChannelInputLine {
  const ChannelInputLine({this.draft = '', this.error, this.disabledHint});

  /// The current draft (cursor rendered at its end).
  final String draft;

  /// The last post failure, shown on a line above the input.
  final String? error;

  /// Non-null: posting is impossible here and the line renders this
  /// one-line hint instead of a draft.
  final String? disabledHint;
}

/// The input line's key routing: typing builds a draft, Backspace
/// edits, Enter posts, Esc releases input focus back to the pane (the
/// draft is kept). Append-at-end editing — the model-picker
/// convention; no mid-line cursor this round.
///
/// While the pane's modal is open it is offered every event before the
/// editor (ModalSurface), so a composing pane consumes typing; when
/// the pane is closed the composer is never consulted and the app's
/// keys flow unchanged. Pure state plus a [post] callback — tests
/// drive it with an in-memory store, no console attached.
final class ChannelComposer {
  ChannelComposer({required this.canPost});

  /// Whether posting is possible at all (an identity plus a writable
  /// store). When false the composer never activates and typing falls
  /// through to the pane's browse handling.
  final bool canPost;

  bool _active = false;

  /// The draft text. Public for the renderer; edits go through
  /// [handle].
  String draft = '';

  /// The last post failure; null after a clean post or any edit.
  String? error;

  /// Whether the input line is shown (the pane is composing).
  bool get isActive => _active;

  /// Enter input mode (show the line). No-op when posting is off.
  void activate() {
    if (canPost) _active = true;
  }

  /// Handles one event for the input line. Returns true when consumed;
  /// false lets the pane's browse handling (or, when the pane is
  /// closed, the application) have the event. [post] receives the
  /// trimmed text and returns an error message, or null on success —
  /// on success the draft clears, on failure it is kept for retry.
  bool handle(InputEvent event,
      {required String? Function(String text) post}) {
    if (!canPost) return false;
    if (event is EscapeKey) {
      if (!_active) return false;
      _active = false; // out of input mode; the draft survives
      return true;
    }
    if (event is CharInput) {
      _active = true; // typing from browse mode starts composing
      draft += event.text;
      error = null;
      return true;
    }
    if (event is PasteInput) {
      _active = true;
      draft = _appendPaste(draft, event.text);
      error = null;
      return true;
    }
    if (!_active) return false;
    if (event is ControlKey) {
      switch (event.code) {
        case ControlCode.backspace:
          // Backspace on an empty draft is a claimed no-op: removeLast
          // on an empty rune list throws a RangeError that escapes the
          // zone guard and kills the process (owner report, v0.10.20).
          if (draft.isEmpty) return true;
          draft = String.fromCharCodes(draft.runes.toList()..removeLast());
          error = null;
          return true;
        case ControlCode.enter:
          final text = draft.trim();
          if (text.isEmpty) return true; // nothing to send, still ours
          error = post(text);
          if (error == null) draft = '';
          return true;
        default:
          break;
      }
    }
    if (event is EditingKey && event.action == EditingAction.killToStart) {
      draft = '';
      error = null;
      return true;
    }
    return false; // arrows, scrolling, …: browse keys, not input keys
  }
}

/// Flattens a bracketed paste onto the single-line draft: newlines and
/// tabs become one space each run (one Enter = one message; a pasted
/// paragraph is one chat line, not several).
String _appendPaste(String draft, String paste) {
  final flat = paste.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (flat.isEmpty) return draft;
  return draft.isEmpty ? flat : '$draft $flat';
}

/// Renders the pane body: the channel list (selected marker, unread
/// badge, counts), the selected channel's recent messages with sender
/// labels and status markers, a presence footer, and — when [input] is
/// given — the input line at the bottom (absent otherwise: the visible
/// focus state). [self] marks that member as `(you)` in the footer.
/// Pure: same inputs, same lines.
List<String> renderChannelPane({
  required List<ChannelSummary> channels,
  required Map<String, int> unread,
  required String selected,
  required List<ChannelMessage> messages,
  required List<ChannelMember> members,
  required int width,
  required int height,
  String? self,
  ChannelInputLine? input,
}) {
  if (width < 8 || height < 3) return const [];
  String clip(String line) =>
      line.length <= width ? line : line.substring(0, width - 1) + '…';

  final body = <String>[];
  for (final channel in channels) {
    final marker = channel.name == selected ? '❯' : ' ';
    final badge = unread[channel.name] ?? 0;
    body.add(clip('$marker ${channel.name}'
        '${badge > 0 ? ' ●$badge' : ''}'
        '  ${channel.messages}msg ${channel.members}mbr'));
  }
  if (body.isEmpty) body.add('no channels');
  body.add('');

  // Header + footer rows, plus the input line and its error row when
  // composing — the message window gets whatever remains.
  final reserved = 2 +
      (input == null ? 0 : 1) +
      (input?.error == null ? 0 : 1);
  final room = height - body.length - reserved;
  final window = messages.length <= room || room < 1
      ? messages
      : messages.sublist(messages.length - room);
  if (window.isEmpty && room >= 1) body.add('(no messages)');
  for (final message in window) {
    body.add(clip(formatChannelLine(message)));
  }

  body.add(members.isEmpty
      ? 'nobody present'
      : 'present: ${members.map((m) => m.name == self ? '${m.name} (you)' : '${m.name} ${m.status}').join(', ')}');
  if (input?.error case final error?) body.add(clip('! $error'));
  if (input != null) {
    body.add(input.disabledHint != null
        ? clip(input.disabledHint!)
        : clip(_inputRow(input.draft, width)));
  }

  final header = input == null
      ? 'Channels · ↑↓ select · type to chat · Esc close'
      : input.disabledHint != null
          ? 'Channels · ↑↓ select · PgUp/PgDn scroll · Esc close'
          : 'Channels · ↑↓ channel · Enter post · Esc back';
  return [
    clip(header),
    ...body,
  ];
}

/// `❯ draft▌` — a block cursor at the end of the draft; long drafts
/// show their tail so the cursor and the newest typing stay visible.
/// An empty draft shows a dim-style placeholder instead.
String _inputRow(String draft, int width) {
  const placeholder = 'message…';
  final budget = width - 3; // '❯ ' prefix + cursor
  if (draft.isEmpty) return '❯ $placeholder▌';
  final tail = budget >= draft.runes.length
      ? draft
      : String.fromCharCodes(
          draft.runes.toList().reversed.take(budget).toList().reversed);
  return '❯ $tail▌';
}

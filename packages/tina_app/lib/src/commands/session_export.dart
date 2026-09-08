import 'package:tina_engine/tina_engine.dart';

/// Renders a saved session as a deterministic markdown transcript.
///
/// Pure: reads only the [SessionManifest] plus the pre-loaded conversation
/// histories and returns a string. No filesystem, no tina_console — safe in
/// headless runs, and trivially testable.
String renderSessionTranscript(
  SessionManifest manifest,
  Map<String, List<Message>> conversations,
) {
  final buf = StringBuffer();
  final title = _deriveTitle(conversations);

  buf.writeln('# Session transcript — ${manifest.id}');
  buf.writeln();
  if (title.isNotEmpty) {
    buf.writeln('> $title');
    buf.writeln();
  }
  buf.writeln(
      '- provider: ${manifest.providerId}'
      '${manifest.baseUrl != null ? ' (`${manifest.baseUrl}`)' : ''}');
  buf.writeln(
      '- conversations: ${manifest.conversations.length}, messages: '
      '${conversations.values.fold<int>(0, (n, m) => n + m.length)}');
  if (manifest.activeConversationId.isNotEmpty) {
    buf.writeln('- active conversation: ${manifest.activeConversationId}');
  }
  buf.writeln();

  for (final conv in manifest.conversations) {
    final messages = conversations[conv.id] ?? const <Message>[];
    buf.writeln('## ${conv.label.isEmpty ? conv.id : conv.label}'
        ' — ${conv.kind.name}'
        '${conv.parentConversationId != null ? ', parent: ${conv.parentConversationId}' : ''}');
    buf.writeln();
    if (messages.isEmpty) {
      buf.writeln('_(no messages)_');
      buf.writeln();
      continue;
    }
    for (final message in messages) {
      buf.writeln('### ${message.role.name}');
      buf.writeln();
      for (final block in message.content) {
        _renderBlock(buf, block);
      }
    }
  }
  return buf.toString();
}

void _renderBlock(StringBuffer buf, ContentBlock block) {
  if (block is TextBlock) {
    buf.writeln(block.text);
    buf.writeln();
  } else if (block is ToolUseBlock) {
    final summary = _toolUseSummary(block);
    buf.writeln('→ tool: ${block.name}'
        '${summary.isNotEmpty ? ' — $summary' : ''}');
    buf.writeln();
  } else if (block is ToolResultBlock) {
    final prefix = 'tool result${block.isError ? ' (error)' : ''}:';
    // A fixed ``` fence breaks the moment the content itself carries one —
    // and tina transcripts constantly do (markdown the model emitted, code
    // blocks in tool output). Use a fence one longer than any backtick run
    // inside the content, so the block always closes where it should.
    final fence = '`' * _fenceLength(block.content);
    buf.writeln(fence);
    buf.writeln(prefix);
    buf.writeln(block.content);
    buf.writeln(fence);
    buf.writeln();
  } else {
    // Unknown block subtype (newer engine version than this client knows).
    _writeUnknown(buf, 'content block');
  }
}

/// One-line human summary of a tool call's arguments: the first non-empty
/// value of the common keys. Kept deliberately shallow — the full input
/// stays in the wire-format session files.
String _toolUseSummary(ToolUseBlock block) {
  if (block.argumentsParseError != null) return 'argument parse error';
  for (final key in const [
    'command',
    'pattern',
    'path',
    'file_path',
    'filePath',
    'query',
    'name',
    'url',
    'args',
    'content'
  ]) {
    final value = block.input[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return '';
}

/// Best-effort title for a saved session: the first user text across the
/// conversations, truncated. The manifest itself stores no title (derived
/// facts are recomputed from the conversation files), so this is the
/// transcript's own view of one.
String _deriveTitle(Map<String, List<Message>> conversations) {
  for (final messages in conversations.values) {
    for (final message in messages) {
      if (message.role != Role.user) continue;
      for (final block in message.content) {
        if (block is TextBlock && block.text.trim().isNotEmpty) {
          final t = block.text.trim();
          return t.length <= 80 ? t : '${t.substring(0, 80)}…';
        }
      }
    }
  }
  return '';
}

void _writeUnknown(StringBuffer buf, String kind) {
  buf.writeln('_($kind — not rendered in this export)_');
  buf.writeln();
}

/// Markdown fence length for a verbatim block: one longer than the longest
/// backtick run in [content] (so a ``` inside the content can't close the
/// fence early), minimum 3. Content without backticks gets the plain fence.
int _fenceLength(String content) {
  var longest = 0;
  var run = 0;
  for (var i = 0; i < content.length; i++) {
    if (content.codeUnitAt(i) == 0x60) {
      run++;
      if (run > longest) longest = run;
    } else {
      run = 0;
    }
  }
  return longest >= 3 ? longest + 1 : 3;
}
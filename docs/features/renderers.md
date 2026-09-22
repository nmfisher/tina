# UI renderers

`Renderer<T>` turns a typed UI value into `RenderLine`s. It is not restricted to
messages: a renderer may accept a transcript block, a status value, or another
type supplied by a UI surface. The shared types live in `tina_console` and do
not depend on the engine or plugin system.

`RenderContext` supplies the available width and theme. `RenderLine` contains
text runs with optional inline styles and a row style (`bar`), including a
background. Renderers must fit their rows within the available width. They are
synchronous, perform no I/O and must not mutate their input. The host owns
screen writes, scrolling, selection and keyboard handling.

## Register a plugin

The frontend's `Renderers` adapter reads the existing plugin registry. It tries
matching typed contributions in registration order, starting at the nearest
scope and then its parents. Returning `null` declines a value; an empty list
produces no rows. If none handles it, the surface's built-in renderer runs.
An exception from a plugin is logged without its message/data and the next
renderer is tried. Removing a registration takes effect on the next render.

For example, this plugin adds a background to assistant prose:

```dart
import 'package:tina/chat/chat_renderer.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/frontend/renderers.dart';
import 'package:tina_engine/tina_engine.dart';

class ReplyRenderer extends Renderer<ChatBlock> {
  @override
  List<RenderLine>? render(ChatBlock block, RenderContext context) {
    if (block.kind != ChatBlockKind.prose) return null;
    final lines = const ChatRenderer().render(block, context);
    return [
      for (final line in lines)
        RenderLine(bar: '44', runs: line.runs),
    ];
  }
}

final replyPlugin = PluginDescriptor(
  id: 'example.reply-style',
  factory: FnPluginFactory((context) {
    final renderer = ReplyRenderer();
    context.register(renderer, id: 'example.reply-style.renderer');
    return renderer;
  }),
);
```

Pass the descriptor through `buildAppComposition(plugins: [replyPlugin], ...)`.
This is the existing Dart plugin composition API, not a new dynamic plugin loader.

## Current integration

All TUI conversation hosts use this hook, including background and spawned
conversations. `ChatRenderer` supplies the current appearance for user prose,
assistant prose, reasoning, tool calls and notices. Streaming segments, tool
updates, folding, selection and resize all render through the same adapter.
Assistant prose is presented in markdown segments, not one block per whole turn.

Approvals use `Renderer<ApprovalCard>` (`package:tina/tui/approval_card.dart`)
for their tool preview, in both conversations and workflow nodes. The built-in
`ApprovalRenderer` shows commands and working directories, existing edit/write
previews, permission scope, and optional execution details. The shared host
owns the inline frame and selectable answers; a renderer cannot change what
an answer grants. Up/Down select, Enter confirms, Tab toggles details, and
PgUp/PgDn or the mouse wheel scroll long previews. A settled card is appended
once; scrolling the pending card never appends transcript copies.

Other UI surfaces can call `Renderers.render` with their own input type and
fallback; menus and the index browser retain their existing rendering.
Headless/passthrough output keeps its plain-text path. Rendered
styles and borders are not added to stored messages or sent to models.

## Conversation border and input prompt

Conversations are borderless by default. The input prompt shows `model > `,
with a rotating `| / - \\` indicator while busy and an unread-line count when
scrolled back. Switching conversations or changing models updates the prompt
without replacing the draft. Workflow and other non-conversation panels keep
their existing borders.

Plugins can register `ConversationStyle(border: true)` to restore conversation
borders, and `Renderer<ConversationPrompt>` to replace the prompt. Both types
are in `package:tina/tui/conversation_style.dart`. For example, inside the
plugin factory:

```dart
context.register(const ConversationStyle(border: true), id: 'chat.style');
context.register(MyPrompt(), id: 'chat.prompt');
```

```dart
class MyPrompt extends Renderer<ConversationPrompt> {
  @override
  List<RenderLine> render(ConversationPrompt value, RenderContext context) => [
    RenderLine(runs: [RenderRun('[${value.model}] > ', context.theme.chat.dim)]),
  ];
}
```

The prompt value carries the conversation ID, model reference, busy/focus state,
keyboard highlight and unread count; the render context supplies the animation
frame. The host uses the first rendered line, clips it to at most half the input
width and leaves the remainder for typing. Input handling, approval forms and
submitted text stay under the host's control. Registration and removal apply
live, including to spawned and restored conversations. These are Dart plugin
contributions through the existing composition API.

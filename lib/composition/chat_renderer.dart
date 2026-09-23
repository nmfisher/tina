import 'package:tina_engine/tina_engine.dart';

import '../chat/chat_renderer.dart';

/// Built-in plugin that publishes the default transcript appearance —
/// [ChatRenderer] — as a scope contribution (`tina.chat-renderer.renderer`)
/// instead of a TUI-internal hardcoded fallback.
///
/// The Renderers-using surfaces (conversation sinks, approval previews)
/// consult the scope first and fall back to the same class when no plugin is
/// mounted, so behavior is identical with or without this descriptor. Its
/// value is the override seam: a runtime activates plugins in plugin-id sort
/// order and the first registered renderer that handles a `ChatBlock` wins,
/// so a plugin whose id sorts before `tina.chat-renderer` (any namespace not
/// prefixed `tina.` — `example.reply-style`, `acme.theme`, ...) replaces the
/// built-in look, and live disposal of `tina.chat-renderer.renderer` drops it
/// for subsequent renders.
///
/// Pure presentation: no services required, nothing to own.
PluginDescriptor chatRendererPlugin() => PluginDescriptor(
  id: 'tina.chat-renderer',
  factory: FnPluginFactory((context) {
    const renderer = ChatRenderer();
    context.register(renderer, id: 'tina.chat-renderer.renderer');
    return renderer;
  }),
);

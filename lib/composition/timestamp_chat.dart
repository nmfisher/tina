import 'package:tina_engine/tina_engine.dart';

import 'package:tina_chat_tui/tina_chat_tui.dart' show TimestampChatRenderer;
export 'package:tina_chat_tui/tina_chat_tui.dart' show TimestampChatRenderer;

/// Optional plugin that stamps each transcript block's first painted line with
/// the time the block first appeared (`HH:mm `, dim). Continuations retain the
/// same indentation. Decorates rather than
/// replaces the built-in look: because the first registered renderer that
/// handles a `ChatBlock` wins, this descriptor's id sorts before
/// `tina.chat-renderer` (plain namespace, per the override recipe in
/// docs/features/renderers.md) and then delegates to [ChatRenderer] itself, so
/// output matches the default row for row — only the gutter differs.
///
/// Where the time comes from: neither `ChatBlock` nor `RenderContext` carries
/// a clock, and `render` runs again on every resize, fold and repaint. The
/// renderer therefore memoizes the *first* render time per block instance in
/// an [Expando] — blocks are append-only and painted the moment they are
/// created (`ChatAgentSink._add`), so first render ≈ creation time, and every
/// later repaint of that instance reuses the same stamp instead of drifting
/// with `DateTime.now()`. The [Expando] holds keys weakly, so a cleared
/// transcript releases its stamps with its blocks.
///
/// Known limit: `replayHistory` rebuilds all blocks at resume time and stored
/// messages carry no per-message timestamp, so a resumed conversation's lines
/// are stamped with resume time rather than their original times.
PluginDescriptor timestampChatPlugin({DateTime Function()? now}) =>
    PluginDescriptor(
      // Must sort before `tina.chat-renderer` (`example.` < `tina.`): an id
      // sorting after the built-in would only see blocks it declines — none.
      id: 'example.timestamp-chat',
      factory: FnPluginFactory((context) {
        final renderer = TimestampChatRenderer(now: now ?? DateTime.now);
        context.register(renderer, id: 'example.timestamp-chat.renderer');
        return renderer;
      }),
    );

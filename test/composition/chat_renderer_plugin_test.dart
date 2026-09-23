import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina/composition/chat_renderer.dart';
import 'package:tina/chat/chat_renderer.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/chat/markdown_renderer.dart';
import 'package:tina/frontend/renderers.dart';
import 'package:tina_engine/tina_engine.dart';

/// A renderer that rewrites every prose row, so an override is visible in the
/// painted output.
class _ShoutRenderer extends Renderer<ChatBlock> {
  const _ShoutRenderer();

  @override
  List<RenderLine> render(ChatBlock block, RenderContext context) => [
        RenderLine(runs: [RenderRun('SHOUT', null)]),
      ];
}

PluginDescriptor _shoutPlugin() => PluginDescriptor(
      id: 'test.shout',
      factory: FnPluginFactory((context) {
        context.register(const _ShoutRenderer(), id: 'test.shout.renderer');
        return Object();
      }),
    );

ChatBlock _prose() => ChatBlock.prose(
      const ChatSpeaker(id: 'c1', label: 'main'),
      [MarkdownLine(runs: [MarkdownRun('hello', null)])],
    );

void main() {
  test('the built-in plugin contributes the default chat renderer', () {
    final runtime = PluginRuntime(
      name: 'chat-renderer-test',
      plugins: [chatRendererPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);

    final lines = Renderers(runtime.scope).render(
      _prose(),
      RenderContext(width: 40, theme: const Theme.defaults()),
      fallback: const ChatRenderer(),
    );
    final painted = lines.first.runs.map((r) => r.text).join();
    expect(painted, contains('hello'));
    expect(painted, isNot(contains('SHOUT')),
        reason: 'the built-in must be in the scope, not the fallback path');
  });

  test('a plugin registered earlier overrides the built-in look', () {
    final runtime = PluginRuntime(
      name: 'chat-renderer-override-test',
      plugins: [_shoutPlugin(), chatRendererPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);

    final lines = Renderers(runtime.scope).render(
      _prose(),
      RenderContext(width: 40, theme: const Theme.defaults()),
      fallback: const ChatRenderer(),
    );
    final painted = lines.first.runs.map((r) => r.text).join();
    expect(painted, 'SHOUT',
        reason: 'first registered renderer that handles the block wins');
  });

  test('an override whose id sorts after the built-in does NOT win', () {
    // `tina.zzz-shout` > `tina.chat-renderer`: activation registers the
    // built-in's contribution first, so the built-in keeps the surface and
    // the late renderer only takes blocks the built-in declines.
    final runtime = PluginRuntime(
      name: 'chat-renderer-order-test',
      plugins: [
        chatRendererPlugin(),
        _plugin('tina.zzz-shout', 'tina.zzz-shout.renderer'),
      ],
    )..activateSync();
    addTearDown(runtime.dispose);

    final lines = Renderers(runtime.scope).render(
      _prose(),
      RenderContext(width: 40, theme: const Theme.defaults()),
      fallback: const ChatRenderer(),
    );
    final painted = lines.first.runs.map((r) => r.text).join();
    expect(painted, contains('hello'));
    expect(painted, isNot(contains('SHOUT')));
  });

  test('overriding does not depend on the plugins list order', () {
    // Same two plugins as above, opposite list order: the id sort, not the
    // list, decides registration order (`tina.` > `test.`).
    final runtime = PluginRuntime(
      name: 'chat-renderer-list-order-test',
      plugins: [_shoutPlugin(), chatRendererPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);

    final lines = Renderers(runtime.scope).render(
      _prose(),
      RenderContext(width: 40, theme: const Theme.defaults()),
      fallback: const ChatRenderer(),
    );
    final painted = lines.first.runs.map((r) => r.text).join();
    expect(painted, 'SHOUT');
  });

  test('a plain-namespace plugin id sorts before tina and overrides', () {
    // The documented override recipe: any id not prefixed `tina.` sorts first.
    final runtime = PluginRuntime(
      name: 'chat-renderer-namespace-test',
      plugins: [_plugin('example.reply-style', 'example.reply-style.renderer')],
    )..activateSync();
    addTearDown(runtime.dispose);
    final registration = runtime.scope.contributions.single;
    expect(registration.id, 'example.reply-style.renderer');

    final lines = Renderers(runtime.scope).render(
      _prose(),
      RenderContext(width: 40, theme: const Theme.defaults()),
      fallback: const ChatRenderer(),
    );
    expect(lines.first.runs.map((r) => r.text).join(), 'SHOUT');
  });
}

PluginDescriptor _plugin(String id, String rendererId) => PluginDescriptor(
      id: id,
      factory: FnPluginFactory((context) {
        context.register(const _ShoutRenderer(), id: rendererId);
        return Object();
      }),
    );

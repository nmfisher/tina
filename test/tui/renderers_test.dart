import 'package:test/test.dart';
import 'package:tina/chat/chat_renderer.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/chat/markdown_renderer.dart';
import 'package:tina/frontend/renderers.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_stdio.dart';

class Status {
  final String text;
  const Status(this.text);
}

class StatusRenderer extends Renderer<Status> {
  final String prefix;
  const StatusRenderer(this.prefix);
  @override
  List<RenderLine> render(Status value, RenderContext context) => [
    RenderLine(runs: [RenderRun('$prefix${value.text}', null)]),
  ];
}

class BrokenRenderer extends Renderer<Object> {
  @override
  List<RenderLine> render(Object value, RenderContext context) =>
      throw StateError('bad plugin');
}

/// An example plugin: borders and background for assistant prose only.
class BoxRenderer extends Renderer<ChatBlock> {
  final widths = <int>[];
  @override
  List<RenderLine>? render(ChatBlock value, RenderContext context) {
    if (value.kind != ChatBlockKind.prose || context.width < 16) return null;
    widths.add(context.width);
    final body = const ChatRenderer().render(
      value,
      RenderContext(width: context.width - 4, theme: context.theme),
    );
    final edge = '+${'-' * (context.width - 2)}+';
    return [
      RenderLine(bar: '44', runs: [RenderRun(edge, null)]),
      for (final line in body)
        RenderLine(
          bar: '44',
          runs: [
            const RenderRun('| ', null),
            ...line.runs,
            RenderRun(
              '${' ' * (context.width - 4 - plainWidth(line.runs.map((r) => r.text).join()))} |',
              null,
            ),
          ],
        ),
      RenderLine(bar: '44', runs: [RenderRun(edge, null)]),
    ];
  }
}

String text(List<RenderLine> lines) =>
    lines.map((line) => line.runs.map((run) => run.text).join()).join('\n');

void main() {
  const context = RenderContext(width: 80, theme: Theme.defaults());
  test(
    'typed non-message renderers use live scoped registrations and fallback',
    () async {
      final parent = PluginScope('parent');
      final child = parent.child('child');
      addTearDown(parent.dispose);
      parent.registerContribution(
        pluginId: 'test',
        id: 'parent',
        contribution: const StatusRenderer('parent:'),
      );
      // Different input types are safely skipped; plugin errors do not break UI.
      child.registerContribution(
        pluginId: 'test',
        id: 'chat',
        contribution: BoxRenderer(),
      );
      child.registerContribution(
        pluginId: 'test',
        id: 'broken',
        contribution: BrokenRenderer(),
      );
      final first = child.registerContribution(
        pluginId: 'test',
        id: 'first',
        contribution: const StatusRenderer('first:'),
      );
      final second = child.registerContribution(
        pluginId: 'test',
        id: 'second',
        contribution: const StatusRenderer('second:'),
      );
      final renderers = Renderers(child);
      String draw() => text(
        renderers.render(
          const Status('ready'),
          context,
          fallback: const StatusRenderer('default:'),
        ),
      );
      expect(draw(), 'first:ready');
      await first.dispose();
      expect(draw(), 'second:ready');
      await second.dispose();
      expect(draw(), 'parent:ready');
      await parent.dispose();
      expect(draw(), 'default:ready');
    },
  );

  test(
    'plugin prose layout survives streaming, resize, folding and removal',
    () async {
      final box = BoxRenderer();
      late Registration registration;
      final runtime = PluginRuntime(
        name: 'ui-test',
        plugins: [
          PluginDescriptor(
            id: 'boxes',
            factory: FnPluginFactory((context) {
              registration = context.register(box, id: 'boxes');
              return box;
            }),
          ),
        ],
      );
      await runtime.activate();
      addTearDown(runtime.dispose);
      final screen = Screen(
        io: FakeStdio()..columns = 160,
        layout: ScreenLayout.fromSize(160, 60),
        ansi: AnsiCapable.yes,
      );
      final chat = ScrollingTextRegion(screen);
      final host = TuiConversationHost(
        conversationId: 'test',
        chat: chat,
        screen: screen,
        spinner: Spinner(enabled: false),
        renderers: Renderers(runtime.scope),
      );
      addTearDown(host.dispose);
      String painted() => [
        for (var row = 0; row < chat.bounds.height; row++)
          chat.debugPaintedText(row) ?? '',
      ].join('\n');

      host.showMessage('hello', style: HostMessageStyle.user);
      host.text('assistant **styled** ');
      host.text('answer\n\n');
      host.newline();
      expect(painted(), contains('+---'));
      expect(painted(), contains('you │ hello'));
      expect(host.lastRawMarkdown, 'assistant **styled** answer\n\n');
      final prose = host.transcript.blocks.indexWhere(
        (b) => b.kind == ChatBlockKind.prose,
      );
      expect(
        host.transcript.endRowOfBlock(prose)! -
            host.transcript.rowOfBlock(prose)!,
        greaterThanOrEqualTo(2),
      );
      final rendered = box.render(host.transcript.blocks[prose], context)!;
      expect(rendered.every((line) => line.bar == '44'), isTrue);

      host.toolStart(
        const ToolStartEvent('bash', 'call', {'command': 'echo tool'}),
      );
      host.toolComplete(
        const ToolCompleteEvent(
          'bash',
          'call',
          isError: false,
          result: 'tool output',
        ),
      );
      final tool = host.transcript.blocks.indexWhere(
        (b) => b.kind == ChatBlockKind.toolCall,
      );
      expect(host.transcript.toggleFold(tool), isTrue);
      expect(painted(), contains('tool output'));
      host.transcript.highlightBlock(prose);
      expect(
        painted(),
        contains('tool output'),
        reason: 'selecting earlier content must preserve later rows',
      );
      host.transcript.highlightBlock(null);

      final oldWidth = chat.bounds.width;
      screen.resize(ScreenLayout.fromSize(100, 60));
      chat.handleResize();
      host.transcript.rerender();
      expect(box.widths.last, chat.bounds.width);
      expect(box.widths.last, isNot(oldWidth));
      expect(painted(), contains('+---'));
      expect(painted(), contains('tool output'));

      await registration.dispose();
      host.transcript.rerender();
      expect(painted(), isNot(contains('+---')));
      expect(painted(), contains('assistant '));
      expect(painted(), contains('styled'));
      expect(painted(), contains(' answer'));
      expect(painted(), contains('tool output'));
      expect(host.lastRawMarkdown, 'assistant **styled** answer\n\n');
    },
  );

  test('inline styling restores a renderer background after each span', () {
    const line = RenderLine(
      bar: '44',
      runs: [RenderRun('bold', '1'), RenderRun(' plain', null)],
    );
    final serialized = serializeLine(line, const MarkdownStyle(), styled: true);
    expect(serialized.bar, '44');
    expect(serialized.text, '\x1b[1mbold\x1b[0m\x1b[44m plain');
  });

  test('passthrough output does not run UI renderers', () async {
    final scope = PluginScope('test');
    addTearDown(scope.dispose);
    final box = BoxRenderer();
    scope.registerContribution(pluginId: 'test', id: 'box', contribution: box);
    final screen = Screen.passthrough(FakeStdio());
    final host = TuiConversationHost(
      conversationId: 'test',
      chat: ScrollingTextRegion(screen),
      screen: screen,
      spinner: Spinner(enabled: false),
      renderers: Renderers(scope),
    );
    addTearDown(host.dispose);
    host.text('plain reply\n\n');
    host.newline();
    expect(box.widths, isEmpty);
  });
}

import 'dart:async';
import 'dart:io';
import 'package:tina/config.dart';
import 'package:tina/tui_coordinator.dart';
import '../helpers/fake_environment.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_terminal_geometry.dart';
import '../helpers/memory_session_store.dart';
import 'package:test/test.dart';
import 'package:tina/tui/input_status.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_stdio.dart';

class Source implements StatusSource {
  final values = <String, String>{};
  final updates = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => updates.stream;
  @override
  Object? read(String id) => values[id];
}

class TextRenderer extends Renderer<String> {
  @override
  List<RenderLine> render(String value, RenderContext context) => [
    RenderLine(runs: [RenderRun(value, null)]),
  ];
}

void main() {
  test(
    'the running TUI paints the Git plugin status after submission',
    () async {
      final temp = Directory.systemTemp.createTempSync('tina-input-status-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (_) => FakeProvider.done(),
          ),
        );
      final config = Config.parse(
        ['--model', 'test/model', '--backend', 'ansi'],
        env: const {},
        registry: registry,
      );
      final result = Completer<GitIntent?>();
      final entered = Completer<void>();
      final app = await buildAppComposition(
        config: config,
        registry: registry,
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
        environment: FakeEnvironment(
          env: {'HOME': temp.path, 'COCOON_UPDATE_CHECK': '0'},
        ),
        plugins: [
          gitInputPlugin(
            classify: (input, cancellation) {
              entered.complete();
              return result.future;
            },
          ),
          PluginDescriptor(
            id: 'test.renderer',
            factory: FnPluginFactory((context) {
              context.register(const GitStatusRenderer(), id: 'git.renderer');
              return Object();
            }),
          ),
        ],
      );
      final io = FakeStdio()..hasTerminalValue = false;
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
      );
      coordinator.pendingGitignoreAsk = null;
      final run = coordinator.run();
      try {
        await pumpEventQueue(times: 30);
        io.feedBytes('commit this\r'.codeUnits);
        await entered.future.timeout(const Duration(seconds: 3));
        await pumpEventQueue();
        expect(io.written.toString(), contains('Last input: checking'));
        result.complete(GitIntent(commands: ['commit']));
        await pumpEventQueue();
        expect(io.written.toString(), contains('Last input: git commit'));
      } finally {
        io.feedBytes('/exit\r'.codeUnits);
        await run.timeout(const Duration(seconds: 5));
        io.close();
      }
    },
  );

  test(
    'status uses live plugin renderers and follows focus and removal',
    () async {
      final scope = PluginScope('test');
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24),
        ansi: AnsiCapable.yes,
      );
      var focused = 'a';
      final status = InputStatus(
        screen: screen,
        scope: scope,
        conversationId: () => focused,
      )..start();
      final source = Source()
        ..values.addAll({'a': 'first panel', 'b': 'second panel'});
      addTearDown(() async {
        await status.dispose();
        await scope.dispose();
      });
      scope.registerContribution(
        pluginId: 'test',
        id: 'renderer',
        contribution: TextRenderer(),
      );
      final registration = scope.registerContribution(
        pluginId: 'test',
        id: 'source',
        contribution: source,
        dispose: source.updates.close,
      );
      await Future<void>.delayed(Duration.zero);
      expect(io.written.toString(), contains('first panel'));
      io.written.clear();
      focused = 'b';
      status.refresh();
      expect(io.written.toString(), contains('second panel'));
      expect(io.written.toString(), isNot(contains('first panel')));
      io.written.clear();
      source.values['b'] = 'new result';
      source.updates.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(io.written.toString(), contains('new result'));
      await registration.dispose();
      await Future<void>.delayed(Duration.zero);
      io.written.clear();
      status.refresh();
      expect(io.written.toString(), isNot(contains('new result')));
    },
  );

  test(
    'Git status distinguishes predictions, uncertainty and unavailable service',
    () {
      const renderer = GitStatusRenderer();
      const context = RenderContext(width: 80, theme: Theme.defaults());
      String render(GitStatus status) => renderer
          .render(status, context)
          .expand((l) => l.runs)
          .map((r) => r.text)
          .join();
      expect(
        render(
          GitStatus(
            '1',
            GitPhase.ready,
            GitIntent(commands: ['commit', 'push']),
          ),
        ),
        contains('git commit, push'),
      );
      expect(
        render(GitStatus('1', GitPhase.ready, GitIntent())),
        contains('no Git intent'),
      );
      expect(
        render(GitStatus('1', GitPhase.ready, GitIntent(unknown: true))),
        contains('unclear'),
      );
      expect(
        render(const GitStatus('1', GitPhase.unavailable)),
        contains('unavailable'),
      );
    },
  );
}

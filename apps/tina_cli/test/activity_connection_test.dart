import 'dart:async';
import 'package:test/test.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina/src/snapshot_catalog.dart';
import 'package:tina_activity/tina_activity.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

class _Terminal implements Terminal {
  @override
  void writeln([String? line]) {}
  @override
  Future<String> ask(String prompt) => throw UnimplementedError();
}

class _Tool extends AgentPlugin {
  @override
  String get id => 'test/tool';
  @override
  List<ToolSchema> get tools => [
    ToolSchema(
      name: 'inspect',
      description: '',
      inputSchema: const {},
      describe: (input) => ToolDescription(
        title: 'Inspect file',
        target: input['path'] as String,
      ),
    ),
  ];
}

class _Browser {
  _Browser(Host host, ActivityPlugin plugin)
    : connection = host.connect(role: SessionRole.observer) {
    view = createConsoleView(plugin, connection: connection)! as ActivityView;
  }
  final SessionConnection connection;
  late final ActivityView view;
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen);
  late final context = ConsoleContext(screen: screen, editor: editor);
  ConsoleAttachment? attachment;
  void attach() => attachment = ConsoleAttachment.attach(view, context);
  void detach() {
    attachment?.dispose();
    attachment = null;
  }

  String get transcript => screen.chat.snapshotLines().join('\n');
  void close() {
    detach();
    connection.close();
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

const _call = ToolUseBlock(
  id: 'reused',
  name: 'inspect',
  input: {
    'path': '/work/file',
    'oldString': 'old line',
    'newString': 'new line',
  },
);

void main() {
  test(
    'two activity browsers recover tools without chat and keep their own UI state',
    () async {
      final activity = ActivityPlugin(terminal: _Terminal());
      final host = Host.start(
        HostConfig(
          workingDirectory: '.',
          plugins: [activity, _Tool()],
          snapshotFeatureFor: snapshotFeatureFor,
          providerFactory: (_) => ScriptedProvider([
            scriptedReply('', calls: [_call]),
            scriptedReply('', calls: [_call]),
            scriptedReply('finished'),
          ]),
        ),
      );
      final started = [Completer<void>(), Completer<void>()];
      final finish = [Completer<void>(), Completer<void>()];
      var invocation = 0;
      late void Function(String) progress, output;
      host.session.loop.registerContextExecutor('inspect', (
        _,
        execution,
      ) async {
        final index = invocation++;
        progress = execution.progress;
        output = execution.report;
        execution.progress('child abc running');
        execution.report('prefix\n');
        started[index].complete();
        await finish[index].future;
        return index == 0
            ? const ToolResult(
                'replacement applied',
                elapsed: Duration(milliseconds: 41),
              )
            : const ToolResult(
                '',
                isError: true,
                timedOut: true,
                emptyOutput: true,
                elapsed: Duration(milliseconds: 17),
              );
      });
      final first = _Browser(host, activity)..attach();
      final second = _Browser(host, activity);
      addTearDown(() async {
        for (final signal in finish) if (!signal.isCompleted) signal.complete();
        first.close();
        second.close();
        await host.shutdown();
      });
      // Exercise paging before attaching the second browser.
      for (var i = 0; i < 400; i++) {
        host.session.loop.recordUsage(
          const UsageRecordedEntry(turnId: 'history'),
        );
      }
      final turn = host.send('inspect');
      await started[0].future;
      await waitFor(
        () => first.view.model.records.singleOrNull?.state == 'running',
      );
      second.attach();
      final row = first.view.model.records.single;
      row.expanded = true;
      first.view.toggle();
      final time = row.started;
      expect(time, isNotNull);
      expect(second.view.model.records.single.started, time);
      expect(second.view.model.records.single.label, 'Inspect file');
      expect(second.view.model.records.single.target, '/work/file');
      expect(host.plugins.any((p) => p.id == 'tina/chat-tui'), isFalse);
      for (var i = 0; i < 30; i++) progress('child abc step $i');
      output('x' * 70000);
      await waitFor(() => second.view.model.records.single.truncated);
      expect(first.view.model.records.single, same(row));
      expect(row.expanded, isTrue);
      expect(second.view.model.records.single.expanded, isFalse);
      for (final browser in [first, second]) {
        final record = browser.view.model.records.single;
        expect(record.output.length, 65536);
        expect(record.progressHistory.length, 20);
        expect(record.progressHistory.first, 'child abc step 10');
        expect(record.progressHistory.last, 'child abc step 29');
        expect(
          record.details().join('\n'),
          contains('[live output truncated]'),
        );
      }
      first.detach();
      progress('child abc detached step');
      await waitFor(
        () =>
            second.view.model.records.single.progress.endsWith('detached step'),
      );
      expect(row.progress, 'child abc step 29');
      first.attach();
      expect(first.view.model.records.single.started, time);
      expect(
        first.view.model.records.single.output,
        second.view.model.records.single.output,
      );
      expect(
        first.view.model.records.single.progress,
        'child abc detached step',
      );
      finish[0].complete();
      await started[1].future;
      await waitFor(() => second.view.model.records.length == 2);
      finish[1].complete();
      expect((await turn).stopReason, StopReason.complete);
      await waitFor(
        () =>
            first.view.model.records.last.finished &&
            second.view.model.records.last.finished,
      );
      for (final browser in [first, second]) {
        expect(browser.view.model.records, hasLength(2));
        final completed = browser.view.model.records.first;
        expect(completed.elapsed, const Duration(milliseconds: 41));
        expect(
          completed.details().join('\n'),
          contains('Successful replacement'),
        );
        expect(completed.details().join('\n'), contains('- old line'));
        expect(completed.details().join('\n'), contains('+ new line'));
        expect(browser.view.model.records.last.state, 'timed out');
        expect(browser.view.model.records.last.result!.emptyOutput, isTrue);
        expect(
          browser.view.model.records.last.elapsed,
          const Duration(milliseconds: 17),
        );
        expect(
          'replacement applied'.allMatches(browser.transcript),
          hasLength(1),
        );
      }
      final replay = _Browser(host, activity)..attach();
      addTearDown(replay.close);
      expect(replay.view.model.records, hasLength(2));
      expect(
        replay.view.model.records.first.elapsed,
        const Duration(milliseconds: 41),
      );
      expect(replay.view.model.records.last.state, 'timed out');
      expect(
        replay.transcript,
        isEmpty,
        reason: 'history replay never reprints completion output',
      );
      first.detach();
      second.detach();
      replay.detach();
      host.detachPlugin(activity.id);
      late _Browser reloaded;
      final replacement = ActivityPlugin(terminal: _Terminal());
      host.attachPlugin(
        replacement,
        activate: (_) {
          reloaded = _Browser(host, replacement)..attach();
        },
      );
      addTearDown(reloaded.close);
      expect(
        reloaded.view.model.records.map((record) => record.label),
        ['Inspect file', 'Inspect file'],
        reason: 'live plugin activation includes its history projections',
      );
      expect(
        reloaded.view.model.records.first.details().join('\n'),
        contains('Successful replacement'),
      );
      expect(
        host.session.loop.log.any((e) => e.toJson().containsKey('features')),
        isFalse,
      );
    },
  );

  test(
    'publication failure restores confirmed activity without exposing later output',
    () async {
      final activity = ActivityPlugin(
        terminal: _Terminal(),
        printTranscript: false,
      );
      final host = Host.start(
        HostConfig(
          workingDirectory: '.',
          plugins: [activity, _Tool()],
          snapshotFeatureFor: snapshotFeatureFor,
          providerFactory: (_) => ScriptedProvider([
            scriptedReply('', calls: [_call]),
            scriptedReply('done'),
          ]),
        ),
      );
      final started = Completer<void>(), finish = Completer<void>();
      late void Function(String) output;
      host.session.loop.registerContextExecutor('inspect', (
        _,
        execution,
      ) async {
        output = execution.report;
        started.complete();
        await finish.future;
        return const ToolResult('result');
      });
      final browser = _Browser(host, activity)..attach();
      addTearDown(() async {
        if (!finish.isCompleted) finish.complete();
        browser.close();
        await host.shutdown();
      });
      final turn = host.send('go').then<void>((_) {}, onError: (Object _) {});
      await started.future;
      final broken = host.session.loop.subscribe((entry, event) {
        if (event == LogEvent.appended) throw StateError('write failed');
      });
      expect(
        () => host.session.loop.recordUsage(
          const UsageRecordedEntry(turnId: 'fail'),
        ),
        throwsA(anything),
      );
      output('unconfirmed output');
      await Future<void>.delayed(Duration.zero);
      browser.view.toggle();
      expect(
        browser.view.visibleLines.join('\n'),
        contains('confirmed history'),
      );
      expect(browser.view.model.records.single.output, isEmpty);
      expect(browser.view.model.records.single.finished, isFalse);
      host.session.loop.unsubscribe(broken);
      finish.complete();
      await turn;
    },
  );
}

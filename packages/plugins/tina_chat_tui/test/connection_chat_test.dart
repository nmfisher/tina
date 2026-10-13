import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _Tool extends AgentPlugin {
  @override
  String get id => 'test/tool';
  @override
  List<ToolSchema> get tools => [
        ToolSchema(
            name: 'inspect',
            description: '',
            inputSchema: const {},
            describe: (input) => ToolDescription(
                title: 'Inspect object', target: '${input['path']}'))
      ];
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

final class _WaitingProvider extends LlmProvider {
  _WaitingProvider(this.release) : super('fixture');
  final Future<void> release;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    await release;
    yield const MessageComplete(
        content: [TextBlock('done')], stopReason: 'end_turn');
  }
}

void main() {
  late ChatPlugin chat;
  late Host host;
  late SessionConnection connection;
  late ConnectionChatObservation observation;
  var cap = 10, alerts = false, failProjection = false;
  setUp(() {
    cap = 10;
    alerts = false;
    failProjection = false;
    chat = ChatPlugin(
        model: 'fixture',
        currentTokenCap: () => cap,
        terminalAlertsEnabled: () => alerts,
        showSessionId: false);
    host = Host.start(HostConfig(
        workingDirectory: '.',
        model: 'fixture',
        plugins: [chat, _Tool()],
        providerFactory: (model) => ScriptedProvider([], model: model),
        snapshotFeatureFor: (plugin) => plugin is! ChatPlugin
            ? null
            : SnapshotFeature(() {
                if (failProjection) throw StateError('private error');
                return {
                  ...chat.observation.events.snapshot,
                  'token_cap': chat.observation.tokenCap,
                  'show_session_id': chat.observation.showSessionId,
                  'terminal_alerts_enabled':
                      chat.observation.terminalAlertsEnabled
                };
              },
                listen: chat.observation.events.listenChanges,
                historyMetadata: chat.historyMetadata)));
    connection = host.connect(role: SessionRole.observer);
    observation = ConnectionChatObservation(connection);
  });
  tearDown(() async {
    connection.close();
    await host.shutdown();
  });

  test('coalesced delivery pages every entry and appends only new preview text',
      () async {
    final events = <SessionObservationEvent>[];
    final release = observation.listen(events.add);
    addTearDown(release);
    for (var i = 0; i < 400; i++) {
      host.session.loop
          .recordUsage(const UsageRecordedEntry(turnId: 'history'));
    }
    chat.watch(const SawText('start'));
    await tick();
    final recorded = events.whereType<ObservedEntry>().map((e) => e.entry.seq);
    expect(recorded, List.generate(400, (i) => i));
    for (var i = 0; i < 200; i++) chat.watch(const SawText('!'));
    await tick();
    expect(events.whereType<ObservedReset>(), isEmpty);
    final text = events
        .whereType<ObservedModel>()
        .map((e) => e.event)
        .whereType<SawText>();
    expect(text.map((e) => e.text), ['start', '!' * 200]);
    expect(events.whereType<ObservedEntry>(), hasLength(400));
    release();
    final detachedCount = events.length;
    chat.watch(const SawText(' detached'));
    await tick();
    expect(events, hasLength(detachedCount));
    final replay = <SessionObservationEvent>[];
    final stop = observation.listen(replay.add);
    addTearDown(stop);
    expect(replay.whereType<ObservedEntry>(), hasLength(400));
    expect(
        replay
            .whereType<ObservedModel>()
            .map((e) => (e.event as SawText).text)
            .single,
        'start${'!' * 200} detached');
  });

  test('display settings and model changes arrive without a transcript entry',
      () async {
    final stop = observation.listen((_) {});
    addTearDown(stop);
    var changed = 0;
    final release = observation.listenChanges(() => changed++);
    addTearDown(release);
    expect(observation.tokenCap, 10);
    expect(observation.showSessionId, isFalse);
    expect(observation.terminalAlertsEnabled, isFalse);
    cap = 20;
    alerts = true;
    host.switchModel('next');
    host.refreshSnapshot();
    await tick();
    expect(observation.tokenCap, 20);
    expect(observation.model, 'next');
    expect(observation.terminalAlertsEnabled, isTrue);
    expect(changed, greaterThan(0));
    expect(host.session.loop.log, isEmpty);
  });

  test(
      'finishing a model turn stops chat animation while a command remains busy',
      () async {
    await host.shutdown();
    connection.close();
    final turnRelease = Completer<void>(), commandRelease = Completer<void>();
    chat = ChatPlugin(model: 'fixture');
    host = Host.start(HostConfig(
        workingDirectory: '.',
        plugins: [chat],
        providerFactory: (_) => _WaitingProvider(turnRelease.future),
        snapshotFeatureFor: (_) => SnapshotFeature(
            () => chat.observation.events.snapshot,
            listen: chat.observation.events.listenChanges)));
    host.commands.publish(Command(
        name: 'wait',
        description: '',
        allowWhileRunning: true,
        handler: (_) => commandRelease.future,
        cancel: commandRelease.complete));
    connection = host.connect(role: SessionRole.observer);
    observation = ConnectionChatObservation(connection);
    final release = observation.listenChanges(() {});
    addTearDown(release);
    final controller = host.connect();
    addTearDown(controller.close);
    addTearDown(() {
      if (!turnRelease.isCompleted) turnRelease.complete();
      if (!commandRelease.isCompleted) commandRelease.complete();
    });
    final turn = host.send('go');
    await tick();
    expect(observation.running, true);
    final command = controller.submitRequest('/wait',
        id: controller.requestWindow.id('wait'));
    turnRelease.complete();
    await turn;
    await tick();
    expect(connection.status.busy, true);
    expect(connection.status.running, false);
    expect(observation.running, false);
    expect(command.snapshot.terminal, false);
    expect(controller.cancel([command.snapshot.workId!]), true);
    await command.completed;
    expect(connection.status.busy, false);
  });

  test('a failing listener retires independently and a replacement can replay',
      () async {
    final events = <SessionObservationEvent>[];
    final bad = observation.listen((_) => throw StateError('renderer failed'));
    final good = observation.listen(events.add);
    addTearDown(bad);
    addTearDown(good);
    chat.watch(const SawText('first'));
    await tick();
    chat.watch(const SawText(' second'));
    await tick();
    expect(events.whereType<ObservedModel>(), hasLength(2));
    expect(host.busy, isFalse);
    final replay = <SessionObservationEvent>[];
    final replacement = observation.listen(replay.add);
    addTearDown(replacement);
    expect(((replay.single as ObservedModel).event as SawText).text,
        'first second');
  });

  test('projection failure shows confirmed history and recovers', () async {
    final events = <SessionObservationEvent>[];
    final release = observation.listen(events.add);
    addTearDown(release);
    host.session.loop.recordUsage(const UsageRecordedEntry(turnId: 'safe'));
    chat.watch(const SawText('preview'));
    await tick();
    failProjection = true;
    host.refreshSnapshot();
    await tick();
    expect(events.whereType<ObservedReset>(), hasLength(1));
    expect(events.whereType<ObservedModel>().last.event, isA<SawNotice>());
    failProjection = false;
    host.refreshSnapshot();
    await tick();
    expect((events.whereType<ObservedModel>().last.event as SawText).text,
        'preview');
  });

  test('bounded preview explicitly reports omissions', () async {
    final events = <SessionObservationEvent>[];
    final release = observation.listen(events.add);
    addTearDown(release);
    for (var i = 0; i < 5000; i++) chat.watch(const SawText('x'));
    await tick();
    final preview = events.whereType<ObservedModel>().map((e) => e.event);
    expect(preview.whereType<SawText>().single.text.length, 4096);
    expect(preview.whereType<SawNotice>().single.text, contains('omitted'));
  });

  test('publication failure cannot leak an unconfirmed preview into chat',
      () async {
    final events = <SessionObservationEvent>[];
    final release = observation.listen(events.add);
    addTearDown(release);
    host.session.loop
        .recordUsage(const UsageRecordedEntry(turnId: 'confirmed'));
    await tick();
    final broken = host.session.loop.subscribe((entry, event) {
      if (event == LogEvent.appended) throw StateError('publication failed');
    });
    expect(
        () => host.session.loop
            .recordUsage(const UsageRecordedEntry(turnId: 'unconfirmed')),
        throwsA(anything));
    chat.watch(const SawText('unconfirmed preview'));
    await tick();
    expect(
        events.whereType<ObservedEntry>().map((e) => e.entry.seq).toSet(), {0});
    expect(events.whereType<ObservedModel>().any((e) => e.event is SawText),
        isFalse);
    expect(events.whereType<ObservedModel>().last.event, isA<SawNotice>());
    host.session.loop.unsubscribe(broken);
  });

  test('tool descriptions, progress and completion timing cross as data',
      () async {
    await host.shutdown();
    connection.close();
    chat = ChatPlugin(model: 'fixture');
    host = Host.start(HostConfig(
        workingDirectory: '.',
        plugins: [chat, _Tool()],
        providerFactory: (_) => ScriptedProvider([
              scriptedReply('', calls: [
                const ToolUseBlock(
                    id: 'call', name: 'inspect', input: {'path': '/work'})
              ]),
              scriptedReply('finished'),
            ]),
        snapshotFeatureFor: (plugin) => plugin is! ChatPlugin
            ? null
            : SnapshotFeature(() => chat.observation.events.snapshot,
                listen: chat.observation.events.listenChanges,
                historyMetadata: chat.historyMetadata)));
    final started = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    host.session.loop.registerContextExecutor('inspect', (_, execution) async {
      execution.report('partial');
      execution.progress('checking');
      started.complete();
      await release.future;
      return const ToolResult('partial complete',
          elapsed: Duration(milliseconds: 41));
    });
    final turn = host.send('inspect');
    await started.future;
    connection = host.connect(role: SessionRole.observer);
    observation = ConnectionChatObservation(connection);
    final events = <SessionObservationEvent>[];
    String? description;
    final stop = observation.listen((event) {
      events.add(event);
      if (event
          case ObservedEntry(entry: MessageAppendedEntry(:final message))) {
        for (final block in message.content.whereType<ToolUseBlock>()) {
          description = observation.describe(ToolUse.fromBlock(block))?.summary;
        }
      }
    });
    addTearDown(stop);
    expect(description, 'Inspect object · /work');
    final activity =
        events.whereType<ObservedActivity>().map((e) => e.activity);
    expect(activity.whereType<ToolStarted>(), hasLength(1));
    expect(activity.whereType<ToolProgress>().single.status, 'checking');
    expect(activity.whereType<ToolOutput>().single.text, 'partial');
    release.complete();
    await turn;
    await tick();
    final finished = events
        .whereType<ObservedActivity>()
        .map((e) => e.activity)
        .whereType<ToolFinished>()
        .single;
    expect(finished.result.content, 'partial complete');
    expect(finished.result.elapsed, const Duration(milliseconds: 41));
    final page = connection.history(snapshot: connection.attach().initial);
    expect(page.entries.any((e) => e.containsKey('features')), isTrue);
    expect(
        host.session.loop.log
            .any((entry) => entry.toJson().containsKey('features')),
        isFalse);
  });
}

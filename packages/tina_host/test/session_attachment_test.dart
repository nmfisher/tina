import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

final class _Feature extends AgentPlugin {
  @override
  String get id => 'test/feature';
  final data = <String, Object?>{
    'items': <Object?>[1]
  };
  final listeners = <void Function()>{};
  bool fail = false;
  Map<String, Object?> Function(SessionEntry)? metadata;
  late final source = SnapshotFeature(
      () {
        if (fail) throw StateError('private failure details');
        return data;
      },
      historyMetadata: (entry) => metadata?.call(entry) ?? const {},
      listen: (listener) {
        listeners.add(listener);
        return () => listeners.remove(listener);
      });
  void change(int value) {
    data['items'] = <Object?>[value];
    for (final listener in listeners.toList()) listener();
  }
}

final class _Tool extends AgentPlugin {
  @override
  String get id => 'test/tool';
  @override
  List<ToolSchema> get tools =>
      const [ToolSchema(name: 'wait', description: '', inputSchema: {})];
}

Host start(
        {List<AgentPlugin> plugins = const [],
        List<List<StreamEvent>> replies = const []}) =>
    Host.start(
        HostConfig(
          workingDirectory: '.',
          plugins: plugins,
          providerFactory: (_) => ScriptedProvider(replies),
          snapshotFeatureFor: (plugin) =>
              plugin is _Feature ? plugin.source : null,
        ),
        sessionId: 'same-session-id');

void main() {
  test('frontend activation sees projections and failure releases them',
      () async {
    final host = start();
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    host.session.loop.recordUsage(const UsageRecordedEntry(turnId: 't'));
    final feature = _Feature()..metadata = (_) => {'description': 'ready'};
    late SessionAttachment frontend;
    expect(
        () => host.attachPlugin(feature, activate: (_) {
              frontend = connection.attach();
              expect(frontend.initial.plugins, contains(feature.id));
              expect(frontend.initial.features[feature.id], feature.data);
              final entry =
                  frontend.history(snapshot: frontend.initial).entries.single;
              expect((entry['features'] as Map)[feature.id],
                  {'description': 'ready'});
              throw StateError('frontend failed');
            }),
        throwsStateError);
    expect(feature.listeners, isEmpty);
    expect(host.plugins, isEmpty);
    final rolledBack = (await frontend.next())!.snapshot;
    expect(rolledBack.plugins, isEmpty);
    expect(rolledBack.features, isEmpty);
    frontend.close();

    final replacement = _Feature();
    host.attachPlugin(replacement, activate: (_) {
      frontend = connection.attach();
      expect(frontend.initial.features[replacement.id], replacement.data);
    });
    replacement.change(3);
    expect((await frontend.next())!.snapshot.features[replacement.id], {
      'items': [3]
    });
    expect(replacement.listeners, hasLength(1));
  });

  test('history projection callbacks cannot mutate the committed transcript',
      () async {
    final feature = _Feature();
    final host =
        start(plugins: [feature], replies: [scriptedReply('keep this')]);
    addTearDown(host.shutdown);
    await host.send('input');
    feature.metadata = (entry) {
      if (entry is MessageAppendedEntry) entry.message.content.clear();
      return const {'projected': true};
    };
    final connection = host.connect();
    addTearDown(connection.close);
    final attachment = connection.attach();
    final page = attachment.history(snapshot: attachment.initial);
    final encoded =
        page.entries.where((e) => e['type'] == 'message_appended').last;
    expect(((encoded['message'] as Map)['content'] as List).single,
        containsPair('text', 'keep this'));
    expect(
        host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .last
            .message
            .content
            .whereType<TextBlock>()
            .single
            .text,
        'keep this');
  });

  test('history metadata is isolated JSON and cannot hide committed entries',
      () {
    final feature = _Feature();
    final host = start(plugins: [feature]);
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    host.session.loop.recordUsage(const UsageRecordedEntry(turnId: 't'));
    feature.metadata = (_) => {'items': feature.data['items']};
    final attachment = connection.attach();
    final entry =
        attachment.history(snapshot: attachment.initial).entries.single;
    final projected =
        ((entry['features'] as Map)['test/feature'] as Map)['items'] as List;
    expect(() => projected.add(2), throwsUnsupportedError);
    (feature.data['items'] as List).add(2);
    expect(projected, [1]);
    expect(
        host.session.loop.log.single.toJson().containsKey('features'), isFalse);
    feature.metadata = (_) => throw StateError('secret detail');
    final without =
        attachment.history(snapshot: attachment.initial).entries.single;
    expect(without['seq'], entry['seq']);
    expect(without['type'], entry['type']);
    expect(without['unavailable_features'], ['test/feature']);
    expect(without.toString(), isNot(contains('secret detail')));
  });

  test('snapshot and updates have one ordered handoff and frozen feature data',
      () async {
    final feature = _Feature();
    final host = start(plugins: [feature]);
    addTearDown(host.shutdown);
    final client = host.connect();
    addTearDown(client.close);
    final view = client.attach();
    final initial = view.initial;
    expect(initial.throughSeq, -1);
    expect(initial.plugins, ['test/feature']);
    final items = (initial.features[feature.id] as Map)['items'] as List;
    expect(() => items.add(2), throwsUnsupportedError);
    feature.change(2); // No gap between taking initial and starting a read.
    final update = (await view.next())!;
    expect(update.snapshot.cursor.epoch, initial.cursor.epoch);
    expect(
        update.snapshot.cursor.revision, greaterThan(initial.cursor.revision));
    expect(items, [1]);
    expect((update.snapshot.features[feature.id] as Map)['items'], [2]);
    expect(update.coalesced, isFalse);
  });

  test('slow clients keep one replacement and can page every committed entry',
      () async {
    final host = start();
    addTearDown(host.shutdown);
    final first = host.connect(), second = host.connect();
    addTearDown(first.close);
    addTearDown(second.close);
    final slow = first.attach(), fast = second.attach();
    for (var i = 0; i < 30; i++) {
      host.session.loop.clearHistory();
      final update = (await fast.next())!;
      expect(update.snapshot.throughSeq, i);
      expect(slow.bufferedUpdates, 1);
    }
    final latest = (await slow.next())!;
    expect(latest.coalesced, isTrue);
    expect(latest.snapshot.throughSeq, 29);
    final sequences = <int>[];
    var after = -1;
    while (true) {
      final page =
          slow.history(snapshot: latest.snapshot, afterSeq: after, limit: 7);
      sequences.addAll(page.entries.map((entry) => entry['seq'] as int));
      after = page.nextAfterSeq;
      if (!page.hasMore) break;
    }
    expect(sequences, List.generate(30, (i) => i));
    expect(slow.bufferedUpdates, 0);
    final read = fast.next();
    expect(fast.next, throwsStateError);
    fast.close();
    expect(await read, isNull);
    host.session.loop.clearHistory();
    expect((await slow.next())!.snapshot.throughSeq, 30);
  });

  test('history pages are fixed at a snapshot and reject another runtime epoch',
      () async {
    final host = start(), reopened = start();
    addTearDown(host.shutdown);
    addTearDown(reopened.shutdown);
    final client = host.connect(), other = reopened.connect();
    addTearDown(client.close);
    addTearDown(other.close);
    host.session.loop.clearHistory();
    final view = client.attach(), later = other.attach();
    host.session.loop.clearHistory();
    final page = view.history(snapshot: view.initial);
    expect(page.entries, hasLength(1));
    expect(page.hasMore, isFalse);
    expect(() => page.entries.single['seq'] = 99, throwsUnsupportedError);
    expect(view.initial.status.id, later.initial.status.id);
    expect(view.initial.cursor.epoch, isNot(later.initial.cursor.epoch));
    expect(() => later.history(snapshot: view.initial), throwsArgumentError);
    expect(() => view.history(snapshot: view.initial, limit: 513),
        throwsRangeError);
  });

  test(
      'attach during tools and questions captures accepted inputs and named work',
      () async {
    final host = start(plugins: [
      _Tool()
    ], replies: [
      scriptedReply('',
          calls: [const ToolUseBlock(id: 'call', name: 'wait', input: {})]),
      scriptedReply('next reply'),
    ]);
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final ready = Completer<void>();
    host.session.loop.registerContextExecutor('wait', (_, execution) async {
      execution.report('partial output');
      execution.progress('waiting for answer');
      final answer = host.questions.ask('Continue?');
      ready.complete();
      return ToolResult((await answer).text);
    });
    final turn = connection.submit('run');
    await ready.future;
    expect(connection.offerInput('next input'), isTrue);
    final first = connection.attach();
    final snapshot = first.initial;
    expect(
        snapshot.activeTools['call'], containsPair('output', 'partial output'));
    expect(snapshot.activeTools['call'],
        containsPair('status', 'waiting for answer'));
    expect(snapshot.questions.single.prompt, 'Continue?');
    expect(snapshot.pendingInputs.single.text, 'next input');
    expect(snapshot.activeWork.single.kind, 'turn');
    final pending = first.next();
    first.close();
    expect(await pending, isNull);
    final second = connection.attach();
    expect(second.initial.questions.single.id, snapshot.questions.single.id);
    connection.questions.answer(snapshot.questions.single.id, 'yes');
    await turn;
    await tick();
    final done = (await second.next())!.snapshot;
    expect(done.activeTools, isEmpty);
    expect(done.questions, isEmpty);
    expect(done.pendingInputs, isEmpty);
    expect(done.status.running, isFalse);
  });

  test('feature failures and reloads are isolated and release observations',
      () async {
    final feature = _Feature();
    final host = start(plugins: [feature]);
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final view = connection.attach();
    expect(feature.listeners, hasLength(1));
    feature.fail = true;
    feature.change(2);
    final failed = (await view.next())!.snapshot;
    expect(failed.unavailableFeatures, [feature.id]);
    expect(failed.features, isEmpty);
    host.detachPlugin(feature.id);
    expect(feature.listeners, isEmpty);
    final replacement = _Feature()..change(3);
    host.attachPlugin(replacement);
    final restored = (await view.next())!.snapshot;
    expect(restored.unavailableFeatures, isEmpty);
    expect((restored.features[feature.id] as Map)['items'], [3]);
    await host.shutdown();
    expect(replacement.listeners, isEmpty);
    expect((await view.next())!.snapshot.status.closed, isTrue);
  });

  test('publication failures never advance the advertised history prefix',
      () async {
    final host = start();
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    host.session.loop.clearHistory();
    final view = connection.attach();
    final handle = host.session.loop.subscribeBatches((entries, event) {
      if (event == LogEvent.appended) throw StateError('store write failed');
    });
    expect(host.session.loop.clearHistory, throwsStateError);
    host.session.loop.unsubscribe(handle);
    // A later success cannot conceal the earlier failed publication.
    host.session.loop.clearHistory();
    final snapshot = (await view.next())!.snapshot;
    expect(snapshot.historyPublicationFailed, isTrue);
    expect(snapshot.throughSeq, 0);
    expect(view.history(snapshot: snapshot).entries, hasLength(1));
    expect(
        () => host.session.loop
            .publishedEntries(afterSeq: -1, throughSeq: 2, limit: 10),
        throwsRangeError);
  });

  test('attachment cannot read inside persistence callbacks', () async {
    final host = start();
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    var checked = false;
    host.session.loop.subscribeBatches((entries, event) {
      if (event == LogEvent.appended) {
        checked = true;
        expect(connection.attach, throwsStateError);
      }
    });
    host.session.loop.clearHistory();
    expect(checked, isTrue);
    expect(connection.attach().initial.throughSeq, 0);
  });

  test('reentrant publication advances only after the entire dispatch succeeds',
      () async {
    final host = start();
    addTearDown(host.shutdown);
    var nested = false;
    host.session.loop.subscribeBatches((entries, event) {
      if (event != LogEvent.appended) return;
      expect(host.session.loop.publishedSeq, -1);
      if (!nested) {
        nested = true;
        host.session.loop.clearHistory();
        expect(host.session.loop.publishedSeq, -1);
      }
    });
    host.session.loop.clearHistory();
    expect(host.session.loop.publishedSeq, 1);
  });
}

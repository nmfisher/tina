import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_compaction/tina_compaction.dart';

final class CaptureProvider implements LlmProvider {
  CaptureProvider(this.model);
  @override
  final String model;
  bool closed = false;
  final requests = <List<Message>>[];
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(List.of(messages));
    yield const MessageComplete(
        content: [TextBlock('answer')], stopReason: 'end_turn');
  }

  @override
  void close() => closed = true;
}

void main() {
  late Directory directory;
  late String config;
  final providers = <CaptureProvider>[];
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tina-controls-');
    config = '${directory.path}/config';
    File(config).writeAsStringSync('''
[default]
model = "first"
[plugins]
enabled = ["tina/session-controls", "tina/auto-compact", "tina/persistence"]
''');
    providers.clear();
  });
  tearDown(() => directory.deleteSync(recursive: true));
  TuiAssembly open({String? resume, String? model}) => TuiAssembly.start(
      providerFactory: (model) {
        if (model == 'bad') throw StateError('invalid model');
        final p = CaptureProvider(model);
        providers.add(p);
        return p;
      },
      options: AssemblyOptions(
          configPath: config,
          workingDirectory: directory.path,
          sessionId: resume,
          model: model));

  test(
      'model switching preserves history, closes old provider and restores on resume',
      () async {
    final app = open();
    final id = app.host.session.id;
    await app.host.send('before');
    await app.commands['model']!.handler('second');
    expect(app.host.model, 'second');
    expect(providers.first.closed, true);
    await app.host.send('after');
    expect(
        providers.last.requests.single.first.content
            .whereType<TextBlock>()
            .single
            .text,
        'before');
    expect(
        providers.last.requests.single.last.content
            .whereType<TextBlock>()
            .single
            .text,
        'after');
    await app.commands['model']!.handler('bad');
    expect(app.host.model, 'second');
    expect(providers.last.closed, false);
    app.close();
    final resumed = open(resume: id);
    expect(resumed.host.model, 'second');
    expect(providers.last.model, 'second');
    resumed.close();
    final overridden = open(resume: id, model: 'third');
    expect(overridden.host.model, 'third');
    overridden.close();
    final again = open(resume: id);
    expect(again.host.model, 'third');
    again.close();
  });

  test(
      'clear resets derived context, preserves audit entries and survives resume',
      () async {
    final app = open();
    final id = app.host.session.id;
    await app.host.send('forget this');
    final previous = app.host.session.loop.log.length;
    await app.commands['clear']!.handler('');
    expect(app.host.session.loop.derive().messages, isEmpty);
    expect(app.host.session.loop.log.length, previous + 1);
    expect(app.host.session.loop.log.last, isA<ContextClearedEntry>());
    app.close();
    final resumed = open(resume: id);
    addTearDown(resumed.close);
    expect(resumed.host.session.loop.derive().messages, isEmpty);
    await resumed.host.send('fresh');
    expect(providers.last.requests.single, hasLength(1));
  });

  test('manual compaction preserves recent turns and resumes the summary',
      () async {
    final app = open();
    final id = app.host.session.id;
    for (final text in ['old', 'recent', 'newest']) {
      await app.host.send(text);
    }
    await app.commands['compact']!.handler('');
    final messages = app.host.session.loop.derive().messages;
    expect(messages, hasLength(5));
    expect(messages.first.content.whereType<TextBlock>().single.text,
        '$compactionSummaryMarker' 'answer');
    app.close();
    final resumed = open(resume: id);
    addTearDown(resumed.close);
    expect(
        resumed.host.session.loop
            .derive()
            .messages
            .first
            .content
            .whereType<TextBlock>()
            .single
            .text,
        contains('answer'));
  });
}

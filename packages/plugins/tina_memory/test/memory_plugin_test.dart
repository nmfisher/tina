import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_memory/tina_memory.dart';

final class _Disk implements AnswerFiles {
  _Disk(this.map);
  final Map<String, bool> map;
  @override
  bool exists(String path) => map[path] ?? false;
}



/// The plugin wiring: hot tier injected once at session start, tools
/// mounted, answer cache exposed, stores closed with the session.
void main() {
  PluginSession session(String id) => PluginSession(
        id: id,
        workingDirectory: '.',
        notifyChanged: () {},
      );

  TurnContext turn() => TurnContext(
        CancelToken(),
        input: const Input('t', id: 'i'),
        messages: const [],
        promptSections: [],
        pinnedTools: const [],
      );

  test('the hot tier rides the first prompt, then only etiquette',
      () async {
    late MemoryStorePair pair;
    final plugin = MemoryPlugin(
      openStores: () {
        pair = MemoryStorePair(
            InMemoryMemoryStore(), InMemoryMemoryStore(scope: MemoryScope.global));
        pair.project.remember('the seam pattern is the house style',
            category: MemoryCategory.structure, updatedBy: 'prior');
        return pair;
      },
      sessionId: 's1',
    );
    plugin.openSession(session('wire'));
    addTearDown(plugin.closeSession);

    final first = turn();
    plugin.onPrompt(first);
    final firstText = first.promptSections.join('\n');
    expect(firstText, contains('<rolling-memory-hot>'));
    expect(firstText, contains('seam pattern'));
    expect(firstText, contains('<rolling-memory>'));

    final second = turn();
    plugin.onPrompt(second);
    expect(second.promptSections.join('\n'),
        isNot(contains('<rolling-memory-hot>')),
        reason: 'the tier is a session-start injection, not every turn');
    expect(second.promptSections.join('\n'), contains('<rolling-memory>'));
  });

  test('an empty store injects no hot tier (silence)', () async {
    final plugin = MemoryPlugin(
      openStores: () => MemoryStorePair(InMemoryMemoryStore(),
          InMemoryMemoryStore(scope: MemoryScope.global)),
      sessionId: 's1',
    );
    plugin.openSession(session('quiet'));
    addTearDown(plugin.closeSession);
    final context = turn();
    plugin.onPrompt(context);
    expect(context.promptSections.join('\n'),
        isNot(contains('<rolling-memory-hot>')));
  });

  test('the answer cache is exposed with the durable mirror wired',
      () {
    final disk = <String, bool>{'a.dart': true};
    final plugin = MemoryPlugin(
      openStores: () => MemoryStorePair(InMemoryMemoryStore(),
          InMemoryMemoryStore(scope: MemoryScope.global)),
      sessionId: 's1',
      answerFileSystem: _Disk(disk),
    );
    plugin.openSession(session('cache'));
    addTearDown(plugin.closeSession);

    final cache = plugin.answerCache!;
    cache.capture('widget seam', ['a.dart']);
    expect(plugin.storesForUi!.project.list().single.category,
        MemoryCategory.paths,
        reason: 'the mirror rides the project store');
    expect(cache.serve('widget seam layout'), isNotNull);
  });

  test('closeSession closes the stores exactly once', () {
    var opens = 0;
    late MemoryStorePair pair;
    final plugin = MemoryPlugin(
      openStores: () {
        opens++;
        return pair = MemoryStorePair(InMemoryMemoryStore(),
            InMemoryMemoryStore(scope: MemoryScope.global));
      },
      sessionId: 's1',
    );
    plugin.openSession(session('close'));
    plugin.closeSession();
    expect(() => pair.project.list(), throwsA(isA<StateError>()),
        reason: 'in-memory twin: closed is closed');
    expect(opens, 1);
  });

  test('tools mount and execute through the plugin', () async {
    final plugin = MemoryPlugin(
      openStores: () => MemoryStorePair(InMemoryMemoryStore(),
          InMemoryMemoryStore(scope: MemoryScope.global)),
      sessionId: 's1',
    );
    plugin.openSession(session('tools'));
    addTearDown(plugin.closeSession);
    final result = await plugin.executeForTest(
        'memory_remember', {'text': 'x', 'category': 'facts'});
    expect(result.isError, isFalse);
    expect(plugin.tools.map((t) => t.name),
        containsAll(['memory_remember', 'memory_recall', 'memory_forget']));
  });
}


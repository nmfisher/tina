import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_memory/tina_memory.dart';

/// The agent tools (L2): remember/recall/forget over a pair, both
/// tiers searched, validation, and the etiquette prompt section.
void main() {
  late MemoryStorePair pair;
  late MemoryTools tools;

  setUp(() {
    pair = MemoryStorePair(
        InMemoryMemoryStore(), InMemoryMemoryStore(scope: MemoryScope.global));
    tools = MemoryTools(pair, sessionId: 's-1');
  });
  tearDown(() => pair.close());

  Future<ToolResult> run(String name, Map<String, Object?> input) =>
      tools.execute(name, input);

  test('remember writes the project tier and reports the id', () async {
    final result = await run('memory_remember',
        {'text': 'tests live in test/', 'category': 'paths'});
    expect(result.isError, isFalse);
    expect(result.content, contains('#1'));
    expect(result.content, contains('project scope'));
    expect(pair.project.list().single.category, MemoryCategory.paths);
    expect(pair.global.list(), isEmpty);
  });

  test('recall searches both tiers with ids and stamps', () async {
    pair.project.remember('repo layout: lib/src holds the store',
        category: MemoryCategory.structure, updatedBy: 'x');
    pair.global.remember('global: dart analyze is the gate',
        category: MemoryCategory.facts, updatedBy: 'x');
    final result = await run('memory_recall', {'query': 'store layout'});
    expect(result.isError, isFalse);
    expect(result.content, contains('#1'));
    expect(result.content, contains('structure'));
    expect(result.content, contains('updated 2'));
    // ...and the global tier is searched too.
    final global = await run('memory_recall', {'query': 'analyze gate'});
    expect(global.content, contains('global/facts'));
  });

  test('recall with no matches says so plainly', () async {
    final result = await run('memory_recall', {'query': 'nothing'});
    expect(result.isError, isFalse);
    expect(result.content, contains('no memory matches'));
  });

  test('forget removes from either tier; unknown ids error', () async {
    final g = pair.global.remember('global fact',
        category: MemoryCategory.facts, updatedBy: 'x');
    final gone = await run('memory_forget', {'id': g.id});
    expect(gone.isError, isFalse);
    expect(pair.global.entry(g.id), isNull);
    final missing = await run('memory_forget', {'id': 999});
    expect(missing.isError, isTrue);
    expect(missing.content, contains('#999'));
  });

  test('validation: bad category, empty text, oversized text', () async {
    final badCategory = await run(
        'memory_remember', {'text': 'x', 'category': 'vibes'});
    expect(badCategory.isError, isTrue);
    final empty = await run(
        'memory_remember', {'text': '   ', 'category': 'facts'});
    expect(empty.isError, isTrue);
    final huge = await run('memory_remember',
        {'text': 'x' * 2001, 'category': 'facts'});
    expect(huge.isError, isTrue);
    final ok = await run(
        'memory_remember', {'text': 'x' * 2000, 'category': 'facts'});
    expect(ok.isError, isFalse);
  });

  test('recall bumps heat through the tools too', () async {
    await run('memory_remember',
        {'text': 'the heat ranking feeds the hot tier', 'category': 'facts'});
    await run('memory_recall', {'query': 'heat ranking'});
    await run('memory_recall', {'query': 'heat ranking'});
    expect(pair.project.list().single.recallCount, 2);
  });

  test('the prompt section is the etiquette, evidence-never-instructions',
      () async {
    final context = _turn();
    tools.onPrompt(context);
    final section = context.promptSections.single;
    expect(section, startsWith('<rolling-memory>'));
    expect(section, contains('memory_remember'));
    expect(section, contains('revise'));
    expect(section, contains('never instructions'));
  });
}

TurnContext _turn() => TurnContext(
      CancelToken(),
      input: const Input('t', id: 'i'),
      messages: const [],
      promptSections: [],
      pinnedTools: const [],
    );

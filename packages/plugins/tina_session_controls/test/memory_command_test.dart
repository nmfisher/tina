import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_memory/tina_memory.dart';
import 'package:tina_session_controls/tina_session_controls.dart';

final class _Terminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) async => '';
}

/// The handler closes the pair it was given (the CLI's open-use-close
/// discipline). Tests hand out a fresh pair over the SAME backing
/// stores each invocation, with a close that does not end the data —
/// the file-backed equivalent.
final class _UnclosableStore implements MemoryStoreApi {
  _UnclosableStore(this._backing);
  final MemoryStoreApi _backing;
  @override
  MemoryScope get scope => _backing.scope;
  @override
  MemoryEntry remember(String text,
          {required MemoryCategory category, required String updatedBy}) =>
      _backing.remember(text, category: category, updatedBy: updatedBy);
  @override
  MemoryEntry revise(int id, String text,
          {required DateTime expected,
          required String updatedBy,
          MemoryCategory? category}) =>
      _backing.revise(id, text,
          expected: expected, updatedBy: updatedBy, category: category);
  @override
  MemoryEntry? forget(int id) => _backing.forget(id);
  @override
  MemoryEntry? entry(int id) => _backing.entry(id);
  @override
  List<MemoryEntry> recall(String query, {int limit = 20}) =>
      _backing.recall(query, limit: limit);
  @override
  List<MemoryEntry> hottest({int limit = 100}) =>
      _backing.hottest(limit: limit);
  @override
  String get file => _backing.file;
  @override
  List<MemoryEntry> list({MemoryCategory? category}) =>
      _backing.list(category: category);
  @override
  Map<String, Object?> stats() => _backing.stats();
  @override
  AnswerCacheCounters answerCacheCounters(MemoryScope scope) =>
      _backing.answerCacheCounters(scope);
  @override
  void bumpAnswerCache(AnswerCacheCounters delta, MemoryScope scope) =>
      _backing.bumpAnswerCache(delta, scope);
  @override
  void close() {}
}

void main() {
  late InMemoryMemoryStore project;
  late InMemoryMemoryStore global;
  late _Terminal terminal;
  late Command command;

  setUp(() {
    project = InMemoryMemoryStore();
    global = InMemoryMemoryStore(scope: MemoryScope.global);
    terminal = _Terminal();
    command = memoryCommand(
      terminal: terminal,
      openStores: () =>
          MemoryStorePair(_UnclosableStore(project), _UnclosableStore(global)),
    );
  });

  Future<void> run(String argument) async => command.handler(argument);

  test('is not registered without the memory seam', () {
    final plugin = SessionControlsPlugin(
      terminal: _Terminal(),
      currentModel: () => 'm',
      switchModel: (_) {},
      modelCatalog: () => const ModelCatalog(models: ['m']),
    );
    expect(plugin.commands.map((c) => c.name), isNot(contains('memory')));
  });

  test('is registered when the composition supplies the store path', () {
    final plugin = SessionControlsPlugin(
      terminal: _Terminal(),
      currentModel: () => 'm',
      switchModel: (_) {},
      modelCatalog: () => const ModelCatalog(models: ['m']),
      openMemoryStores: () => throw UnimplementedError(),
    );
    expect(plugin.commands.map((c) => c.name), contains('memory'));
  });

  test('list: ids, categories, heat markers, [g] for global, one line',
      () async {
    project.remember('the index lives in packages/tina_index',
        category: MemoryCategory.paths, updatedBy: 's1');
    project.remember('never push directly to main',
        category: MemoryCategory.gotchas, updatedBy: 's1');
    global.remember('prefer small commits everywhere',
        category: MemoryCategory.decisions, updatedBy: 's1');
    // A long entry truncates to one line.
    project.remember('x' * 200,
        category: MemoryCategory.facts, updatedBy: 's1');

    await run('');
    final text = terminal.lines.join('\n');
    expect(text, contains('#1 paths ·0 the index lives in packages/tina_index'));
    expect(text, contains('#2 gotchas ·0 never push directly to main'));
    expect(text, contains('[g] decisions'));
    expect(text, contains('#3 facts ·0 '));
    expect(text, isNot(contains('x' * 100)),
        reason: 'the one-line listing truncates long text');
  });

  test('show: full text plus metadata; list stays one line', () async {
    final entry = project.remember('multi\nline\nfact',
        category: MemoryCategory.facts, updatedBy: 's1');
    await run('');
    expect(terminal.lines.join('\n'), isNot(contains('multi\nline')));
    terminal.lines.clear();

    await run('show ${entry.id}');
    final text = terminal.lines.join('\n');
    expect(text, contains('multi\nline\nfact'));
    expect(text, contains('project/facts'));
    expect(text, contains('by s1'));
  });

  test('search: memory_recall semantics — matches AND bumps heat', () async {
    project.remember('the build needs vendored sqlite',
        category: MemoryCategory.gotchas, updatedBy: 's1');
    project.remember('unrelated entry',
        category: MemoryCategory.facts, updatedBy: 's1');

    await run('sqlite');
    expect(terminal.lines.join('\n'), contains('1 match'));
    expect(terminal.lines.join('\n'), contains('the build needs vendored'));
    expect(project.entry(1)!.recallCount, 1,
        reason: 'a search is a recall: heat bumps, durably');
    expect(project.entry(2)!.recallCount, 0);

    // List and show never mutate heat.
    await run('');
    await run('show 1');
    expect(project.entry(1)!.recallCount, 1);
    expect(project.entry(2)!.recallCount, 0);
  });

  test('stats: per-tier counts and the live scoreboard', () async {
    project.remember('fact one',
        category: MemoryCategory.facts, updatedBy: 's1');
    final cache = const AnswerCacheStats(
        served: 7, accepted: 5, declined: 2, staleDropped: 1,
        estimatedTokensSaved: 1234);
    final withCache = memoryCommand(
      terminal: terminal,
      openStores: () =>
          MemoryStorePair(_UnclosableStore(project), _UnclosableStore(global)),
      readCacheStats: () => cache,
    );

    await withCache.handler('stats');
    final text = terminal.lines.join('\n');
    expect(text, contains('project tier — 1 entries (1 facts)'));
    expect(text, contains('global tier — 0 entries'));
    expect(text, contains('7 served · 5 accepted · 2 declined'));
    expect(text, contains('~1234 tokens saved'));

    // Without a live cache the note names it, like the CLI.
    terminal.lines.clear();
    await run('stats');
    expect(terminal.lines.join('\n'), contains('per-session'));
  });

  test('remember and forget from the keyboard', () async {
    await run('remember always run the tests --category gotchas');
    expect(project.list().single.text, 'always run the tests');
    expect(project.list().single.category, MemoryCategory.gotchas);
    expect(project.list().single.updatedBy, 'human');
    expect(global.list(), isEmpty);

    // --global writes the global tier.
    await run('remember global fact --category facts --global');
    expect(global.list().single.text, 'global fact');

    await run('forget 1');
    expect(project.list().map((e) => e.text), isEmpty);
    expect(global.list(), isNotEmpty);

    terminal.lines.clear();
    await run('forget 99');
    expect(terminal.lines.single, 'no entry #99');
  });

  test('promote: refuses the nonexistent, moves a real one', () async {
    await run('promote 5');
    expect(terminal.lines.single, 'no project entry #5 to promote');

    final entry = project.remember('worth keeping everywhere',
        category: MemoryCategory.decisions, updatedBy: 's1');
    terminal.lines.clear();
    await run('promote ${entry.id}');
    final text = terminal.lines.join('\n');
    expect(text, contains('promoted #1 -> global #1'));
    expect(project.list(), isEmpty);
    expect(global.list().single.text, 'worth keeping everywhere');
  });

  test('completion: subcommands, categories and flags', () async {
    final complete = command.complete!;
    expect(await complete(''), containsAll(['list', 'show', 'stats', 'promote']));
    expect(await complete('re'), ['remember']);
    expect(await complete('go'), ['gotchas']);
    expect(await complete('--g'), ['--global']);
    expect(await complete('--c'), ['--category']);
    expect(await complete('zzz'), isEmpty);
  });

  test('usage and errors are named, never thrown', () async {
    await run('help');
    expect(terminal.lines.join('\n'), contains('usage: /memory'));

    terminal.lines.clear();
    await run('show');
    expect(terminal.lines.join('\n'), contains('show needs an entry id'));

    terminal.lines.clear();
    await run('remember text without category');
    expect(terminal.lines.join('\n'), contains('--category'));
  });
}

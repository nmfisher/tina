import 'package:test/test.dart';
import 'package:tina_memory/tina_memory.dart';

/// The session-start hot tier (L4): ranking, the byte cap, the labeled
/// block with staleness caveat, and silence when empty.
void main() {
  late MemoryStorePair pair;

  setUp(() {
    pair = MemoryStorePair(
        InMemoryMemoryStore(), InMemoryMemoryStore(scope: MemoryScope.global));
  });
  tearDown(() => pair.close());

  test('empty stores inject nothing (silence, not an empty block)', () {
    expect(hotTierBlock(pair), isNull);
  });

  test('entries render with ids, tiers, categories and ages', () {
    pair.project.remember('the store seam lives in tina_memory',
        category: MemoryCategory.structure, updatedBy: 's1');
    final block = hotTierBlock(pair)!;
    expect(block, startsWith('<rolling-memory-hot>'));
    expect(block, contains('#1 (project/structure'));
    expect(block, contains('updated today'));
    expect(block, contains('may be stale'));
    expect(block, contains('memory_recall'));
  });

  test('hottest first: recall count outranks, both tiers included', () {
    pair.project.remember('cold entry',
        category: MemoryCategory.facts, updatedBy: 's');
    pair.global.remember('global gotcha',
        category: MemoryCategory.gotchas, updatedBy: 's');
    pair.project.remember('hot entry',
        category: MemoryCategory.paths, updatedBy: 's');
    pair.recall('hot entry');
    pair.recall('hot entry');
    pair.recall('global gotcha');
    final block = hotTierBlock(pair)!;
    final hotIndex = block.indexOf('hot entry');
    final globalIndex = block.indexOf('global gotcha');
    final coldIndex = block.indexOf('cold entry');
    expect(hotIndex, lessThan(globalIndex), reason: '2 recalls > 1');
    expect(globalIndex, lessThan(coldIndex), reason: 'recalled > never');
  });

  test('the cap cuts between entries and says what it dropped', () {
    for (var i = 1; i <= 60; i++) {
      pair.project.remember(
          'entry number $i with some padding text to consume budget '
          'quickly across many lines of memory',
          category: MemoryCategory.facts,
          updatedBy: 's');
      // Recall the LOW numbers so they stay hottest despite their age.
      if (i <= 10) pair.recall('entry number $i');
    }
    final block = hotTierBlock(pair)!;
    expect(block.runes.length, lessThan(hotTierByteCap + 400),
        reason: 'the block stays bounded');
    expect(block, contains('omitted'), reason: 'the cut is reported');
    expect(block, contains('entry number 1'), reason: 'hottest kept whole');
    expect(block.contains('entry number 25'), isFalse,
        reason: 'the never-recalled tail is cut by the cap');
  });
}

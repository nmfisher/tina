// Live check (L4): fill memory past the cap, show the ranking cut.
import 'package:tina_memory/tina_memory.dart';

void main() {
  final pair = MemoryStorePair(
      InMemoryMemoryStore(), InMemoryMemoryStore(scope: MemoryScope.global));
  for (var i = 1; i <= 40; i++) {
    pair.project.remember(
        'fact $i: the module map spans $i subsystems with shared seams '
        'and each carries its own tests and docs',
        category: MemoryCategory.structure, updatedBy: 'probe');
    if (i <= 3) {
      pair.recall('fact $i');
      pair.recall('fact $i');
    }
  }
  final block = hotTierBlock(pair)!;
  print(block);
  print('--- bytes=${block.runes.length} cap=$hotTierByteCap');
  pair.close();
}

// Live check (L1): two real git checkouts of one origin share the
// memory file; a different origin does not. Transcript for the ticket.
import 'dart:io';

import 'package:tina_memory/tina_memory.dart';
import 'package:tina_memory/tina_memory_sqlite.dart';

String checkout(Directory parent, String name, String url) {
  final dir = Directory('${parent.path}/$name')..createSync();
  Process.runSync('git', ['init', '-q', '.'], workingDirectory: dir.path);
  Process.runSync('git', ['remote', 'add', 'origin', url],
      workingDirectory: dir.path);
  return dir.path;
}

void main() {
  final home = Directory.systemTemp.createTempSync('tina-mem-live-');
  final a = checkout(home, 'checkout-a', 'https://github.com/team/proj.git');
  final b = checkout(home, 'checkout-b', 'git@github.com:team/proj.git');
  print('origins: a=${repoOriginFor(a)} b=${repoOriginFor(b)}');

  final sa = openDefaultMemoryStores(a, environment: {'HOME': home.path});
  sa.project.remember('the answer-cache lives in tina_memory',
      category: MemoryCategory.structure, updatedBy: 'session-in-a');
  print('written from checkout A (https form)');

  final sb = openDefaultMemoryStores(b, environment: {'HOME': home.path});
  final seen = sb.project.recall('answer-cache');
  print('read from checkout B (ssh form): '
      '${seen.map((e) => e.text).toList()}');
  print('shared: ${seen.isNotEmpty}');

  final other = checkout(home, 'other', 'https://github.com/x/y.git');
  final so = openDefaultMemoryStores(other, environment: {'HOME': home.path});
  print('unrelated origin sees it: '
      '${so.project.recall('answer-cache').isNotEmpty}');

  sa.close(); sb.close(); so.close();
  home.deleteSync(recursive: true);
}

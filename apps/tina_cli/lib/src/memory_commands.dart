/// The `tina memory` subcommands: list / show / remember / revise /
/// forget / promote / stats. Routed from runCli before the main flag
/// schema (the channel-subcommand pattern). The human's window into
/// rolling memory — and the ONLY path to promotion (issue 94: global
/// is manual, never automatic) and to the answer-cache scoreboard.
library;

import 'dart:io';

import 'package:tina_memory/tina_memory_sqlite.dart';

const _usage = 'usage: tina memory <list|show|remember|revise|forget|'
    'promote|stats> [args]\n'
    '  tina memory list [--category CAT] [--global]\n'
    '  tina memory show ID [--global]\n'
    '  tina memory remember TEXT --category CAT [--global]\n'
    '  tina memory revise ID TEXT [--force]\n'
    '  tina memory forget ID [--global]\n'
    '  tina memory promote ID            (project -> global, manual only)\n'
    '  tina memory stats\n'
    'options: --cwd DIR (workspace, default .)';

/// Routes a `tina memory ...` invocation. Returns null when [args] is
/// not a memory subcommand (the caller falls through to the main CLI).
Future<int?> runMemorySubcommand(List<String> args,
    {Map<String, String>? environment}) async {
  if (args.isEmpty || args.first != 'memory') return null;
  final rest = args.skip(1).toList();
  final command = rest.isEmpty ? 'help' : rest.first;

  if (command == 'help' || command == '--help' || command == '-h') {
    stdout.writeln(_usage);
    return command == 'help' ? 0 : 0;
  }

  final flags = <String, String>{};
  final positional = <String>[];
  for (var i = 1; i < rest.length; i++) {
    final arg = rest[i];
    if (arg.startsWith('--')) {
      final body = arg.substring(2);
      final eq = body.indexOf('=');
      if (eq >= 0) {
        flags[body.substring(0, eq)] = body.substring(eq + 1);
      } else if (i + 1 < rest.length && !rest[i + 1].startsWith('--')) {
        flags[body] = rest[++i];
      } else {
        flags[body] = '';
      }
    } else {
      positional.add(arg);
    }
  }

  final workspace = flags['cwd'] ?? Directory.current.path;
  final MemoryStorePair stores;
  try {
    stores = openDefaultMemoryStores(workspace, environment: environment);
  } on Object catch (e) {
    stderr.writeln('tina memory: $e');
    return 1;
  }
  // (stores is final-and-assigned on every path past the catch.)
  try {
    final global = flags.containsKey('global');
    switch (command) {
      case 'list':
        return _list(stores, flags, global);
      case 'show':
        if (positional.isEmpty) return _usageError('show needs an id');
        return _show(stores, positional.first, global);
      case 'remember':
        if (positional.isEmpty) {
          return _usageError('remember needs text');
        }
        final category = flags['category'];
        if (category == null) {
          return _usageError('remember needs --category '
              '(paths, structure, decisions, gotchas, facts)');
        }
        return _remember(stores, positional.join(' '),
            MemoryCategory.parse(category), global);
      case 'revise':
        if (positional.length < 2) {
          return _usageError('revise needs an id and text');
        }
        return _revise(stores, positional.first,
            positional.skip(1).join(' '), flags.containsKey('force'));
      case 'forget':
        if (positional.isEmpty) return _usageError('forget needs an id');
        return _forget(stores, positional.first, global);
      case 'promote':
        if (positional.isEmpty) return _usageError('promote needs an id');
        return _promote(stores, positional.first);
      case 'stats':
        return _stats(stores);
      default:
        stderr.writeln('tina memory: unknown subcommand "$command"');
        stderr.writeln(_usage);
        return 64;
    }
  } on MemoryRevisionConflict catch (conflict) {
    stderr.writeln('tina memory: entry #${conflict.current.id} changed '
        'since you last saw it. Current text:');
    stderr.writeln('  ${conflict.current.text}');
    stderr.writeln('Re-run revise against this text, or pass --force to '
        'overwrite.');
    return 1;
  } on FormatException catch (e) {
    stderr.writeln('tina memory: ${e.message}');
    return 64;
  } on Object catch (e) {
    stderr.writeln('tina memory: $e');
    return 1;
  } finally {
    stores.close();
  }
}

int _list(MemoryStorePair stores, Map<String, String> flags, bool global) {
  final category = flags['category'] == null
      ? null
      : MemoryCategory.parse(flags['category']!);
  final entries =
      (global ? stores.global : stores.project).list(category: category);
  if (entries.isEmpty) {
    stdout.writeln('(no ${global ? 'global' : 'project'} memory entries)');
    return 0;
  }
  for (final e in entries) {
    stdout.writeln(_line(e));
  }
  return 0;
}

int _show(MemoryStorePair stores, String idText, bool global) {
  final entry = (global ? stores.global : stores.project)
      .entry(_id(idText, allowZero: false));
  if (entry == null) {
    stderr.writeln('tina memory: no entry #$idText');
    return 1;
  }
  stdout.writeln(_line(entry));
  stdout.writeln('  created ${entry.createdAt.toUtc().toIso8601String()} '
      'by ${entry.updatedBy}');
  return 0;
}

int _remember(MemoryStorePair stores, String text,
      MemoryCategory category, bool global) {
  final entry = (global ? stores.global : stores.project)
      .remember(text, category: category, updatedBy: 'cli');
  stdout.writeln(_line(entry));
  return 0;
}

int _revise(
    MemoryStorePair stores, String idText, String text, bool force) {
  final id = _id(idText, allowZero: false);
  final current =
      stores.project.entry(id) ?? stores.global.entry(id);
  if (current == null) {
    stderr.writeln('tina memory: no entry #$id');
    return 1;
  }
  final store = stores.storeFor(current.scope);
  final entry = force
      ? _forcedRevise(store, current, text)
      : store.revise(id, text,
          expected: current.updatedAt, updatedBy: 'cli');
  stdout.writeln(_line(entry));
  return 0;
}

MemoryEntry _forcedRevise(
    MemoryStoreApi store, MemoryEntry current, String text) {
  // --force loops the guard: re-read and revise against NOW.
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return store.revise(current.id, text,
          expected: store.entry(current.id)!.updatedAt, updatedBy: 'cli');
    } on MemoryRevisionConflict {
      // raced again; retry
    }
  }
  throw StateError('entry #${current.id} keeps changing under --force');
}

int _forget(MemoryStorePair stores, String idText, bool global) {
  final id = _id(idText, allowZero: false);
  final deleted =
      (global ? stores.global : stores.project).forget(id);
  if (deleted == null) {
    stderr.writeln('tina memory: no entry #$idText');
    return 1;
  }
  stdout.writeln('forgot ${_line(deleted)}');
  return 0;
}

int _promote(MemoryStorePair stores, String idText) {
  final id = _id(idText, allowZero: false);
  final entry = stores.project.entry(id);
  if (entry == null) {
    stderr.writeln('tina memory: no project entry #$idText to promote');
    return 1;
  }
  // Manual only (issue 94): move = copy to global, delete from project.
  final promoted = stores.global
      .remember(entry.text, category: entry.category, updatedBy: 'promote');
  stores.project.forget(id);
  stdout.writeln('promoted #${entry.id} -> global #${promoted.id}: '
      '${entry.text}');
  return 0;
}

int _stats(MemoryStorePair stores) {
  for (final store in [stores.project, stores.global]) {
    final stats = store.stats();
    final byCategory = (stats['byCategory'] as Map).cast<String, int>();
    stdout.writeln('${stats['scope']} tier (${stats['file']})');
    stdout.writeln('  entries: ${stats['entries']}'
        '${byCategory.isEmpty ? '' : ' (${byCategory.entries.map((e) => '${e.value} ${e.key}').join(', ')})'}');
    stdout.writeln('  recalls served: ${stats['recalls']}');
  }
  final counters = [
    stores.project.answerCacheCounters(MemoryScope.project),
    stores.global.answerCacheCounters(MemoryScope.global),
  ];
  final total = counters.fold(
      const AnswerCacheCounters(), (a, b) => a + b);
  stdout.writeln('answer cache (persisted, across sessions): '
      '${total.served} served · ${total.accepted} accepted · '
      '${total.declined} declined · ${total.staleDropped} stale dropped · '
      '~${total.tokensSaved} tokens saved');
  return 0;
}

String _line(MemoryEntry e) =>
    '#${e.id} ${e.scope.name}/${e.category.name} '
    '[updated ${e.updatedAt.toUtc().toIso8601String()} '
    'by ${e.updatedBy}, recalled ${e.recallCount}x] ${e.text}';

int _id(String text, {required bool allowZero}) {
  final id = int.tryParse(text);
  if (id == null || (!allowZero && id < 1)) {
    throw FormatException('"$text" is not an entry id');
  }
  return id;
}

int _usageError(String problem) {
  stderr.writeln('tina memory: $problem');
  stderr.writeln(_usage);
  return 64;
}

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_memory/tina_memory.dart';

/// The `/memory` command: the human's window into rolling memory from
/// the TUI — list, search, show, stats, plus the remember / forget /
/// promote mutators (the agent-side tools stay the primary path; the
/// keyboard gets the same powers so there is one mental model).
///
/// The store is opened EXACTLY the way the CLI opens it
/// (`openDefaultMemoryStores` on the workspace) and closed after each
/// command — no long-lived connection is invented here. The command is
/// registered only where the composition supplies that opener
/// (`SessionControlsPlugin.openMemoryStores`), which keeps it off the
/// wasm engine path by construction.
///
/// Read-mostly: listing and showing never touch heat. A search matches
/// `memory_recall`'s semantics — `MemoryStorePair.recall` searches both
/// tiers AND BUMPS the heat of what it surfaces (documented in
/// docs/rolling_memory.md).
const _usage = 'usage: /memory [list|show|stats|remember|forget|promote|help] '
    '[args]  (a bare /memory <query> searches, like memory_recall)\n'
    '  /memory                          list entries (project + [g] global)\n'
    '  /memory <query>                  keyword search both tiers (bumps '
    'heat, like memory_recall)\n'
    '  /memory list [--category CAT]    list, filtered by category\n'
    '  /memory show ID [--global]       full text of one entry\n'
    '  /memory stats                    scoreboard + per-tier counts\n'
    '  /memory remember TEXT --category CAT [--global]\n'
    '  /memory forget ID [--global]\n'
    '  /memory promote ID               project -> global (manual only)';

/// The subcommand words (completion's first vocabulary).
const memorySubcommands = [
  'list',
  'show',
  'stats',
  'remember',
  'forget',
  'promote',
  'help',
];

/// Builds the command. [openStores] follows the CLI's store-opening
/// path and is called once per invocation (the pair is closed after);
/// [readCacheStats] supplies the live session scoreboard for `stats`
/// when the composition has a memory plugin.
Command memoryCommand({
  required Terminal terminal,
  required MemoryStorePair Function() openStores,
  AnswerCacheStats? Function()? readCacheStats,
}) {
  return Command(
    name: 'memory',
    description: 'browse rolling memory: list, search, show, stats, '
        'remember, forget, promote (a bare query searches)',
    allowWhileRunning: true,
    complete: (prefix) => _complete(prefix),
    handler: (argument) async {
      final stores = openStores();
      try {
        _run(terminal, stores, argument.trim(), readCacheStats);
      } on FormatException catch (e) {
        terminal.writeln('memory: ${e.message}');
        terminal.writeln(_usage);
      } on Object catch (e) {
        terminal.writeln('memory: $e');
      } finally {
        stores.close();
      }
    },
  );
}

/// The CLI's argument conventions (memory_commands.dart): `--flag`,
/// `--flag value`, `--flag=value`, everything else positional.
({Map<String, String> flags, List<String> positional}) parseMemoryArguments(
    String argument) {
  final flags = <String, String>{};
  final positional = <String>[];
  final words = argument.trim().isEmpty
      ? const <String>[]
      : argument.trim().split(RegExp(r'\s+'));
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (word.startsWith('--')) {
      final body = word.substring(2);
      final eq = body.indexOf('=');
      if (eq >= 0) {
        flags[body.substring(0, eq)] = body.substring(eq + 1);
      } else if (i + 1 < words.length && !words[i + 1].startsWith('--')) {
        flags[body] = words[++i];
      } else {
        flags[body] = '';
      }
    } else {
      positional.add(word);
    }
  }
  return (flags: flags, positional: positional);
}

void _run(Terminal terminal, MemoryStorePair stores, String argument,
    AnswerCacheStats? Function()? readCacheStats) {
  final parsed = parseMemoryArguments(argument);
  final flags = parsed.flags;
  final positional = parsed.positional;
  final global = flags.containsKey('global');
  final subcommand = positional.isEmpty ? 'list' : positional.first;

  // A bare query (any word that is not a subcommand) searches both
  // tiers — memory_recall's semantics, heat bump included.
  if (positional.isNotEmpty && !memorySubcommands.contains(subcommand)) {
    _search(terminal, stores, argument);
    return;
  }
  switch (subcommand) {
    case 'list':
      final category = flags['category'] == null
          ? null
          : MemoryCategory.parse(flags['category']!);
      _list(terminal, stores, category);
    case 'help':
      terminal.writeln(_usage);
    case 'show':
      if (positional.length < 2) {
        throw const FormatException('show needs an entry id');
      }
      _show(terminal, stores, positional[1], global);
    case 'stats':
      _stats(terminal, stores, readCacheStats);
    case 'remember':
      if (positional.length < 2) {
        throw const FormatException('remember needs text');
      }
      final category = flags['category'];
      if (category == null) {
        throw const FormatException(
            'remember needs --category (paths, structure, decisions, '
            'gotchas, facts)');
      }
      _remember(terminal, stores, positional.skip(1).join(' '),
          MemoryCategory.parse(category), global);
    case 'forget':
      if (positional.length < 2) {
        throw const FormatException('forget needs an entry id');
      }
      _forget(terminal, stores, positional[1], global);
    case 'promote':
      if (positional.length < 2) {
        throw const FormatException('promote needs an entry id');
      }
      _promote(terminal, stores, positional[1]);
    default:
      throw FormatException('unknown subcommand "$subcommand"');
  }
}

/// Heat marker for a recall count: cold `·`, warm `▪`, hot `■`.
String _heat(int recallCount) {
  if (recallCount >= 3) return '■$recallCount';
  if (recallCount >= 1) return '▪$recallCount';
  return '·0';
}

/// One listing line: id, global marker, category, heat, one-line text.
String _memoryLine(MemoryEntry entry, {int textWidth = 80}) {
  final marker = entry.scope == MemoryScope.global ? '[g] ' : '';
  return '#${entry.id} $marker${entry.category.name} ${_heat(entry.recallCount)} '
      '${_oneLine(entry.text, textWidth)}';
}

String _oneLine(String text, int width) {
  final line = text.replaceAll('\n', ' ').trim();
  return line.length <= width ? line : '${line.substring(0, width - 1)}…';
}

void _list(Terminal terminal, MemoryStorePair stores, MemoryCategory? category) {
  // Project scope by default; global entries appear with [g] so the
  // listing shows the whole picture in one place.
  final entries = [
    ...stores.project.list(category: category),
    ...stores.global.list(category: category),
  ];
  if (entries.isEmpty) {
    terminal.writeln('(no memory entries'
        '${category == null ? '' : ' in ${category.name}'})');
    return;
  }
  for (final entry in entries) {
    terminal.writeln(_memoryLine(entry));
  }
}

void _search(Terminal terminal, MemoryStorePair stores, String query) {
  // recall = memory_recall's semantics: both tiers, heat-ranked — and
  // the heat of what it surfaces bumps (browsing by search is a
  // recall; list and show never mutate).
  final entries = stores.recall(query, limit: 20);
  if (entries.isEmpty) {
    terminal.writeln('no memory matches "$query"');
    return;
  }
  terminal.writeln('${entries.length} match'
      '${entries.length == 1 ? '' : 'es'} for "$query" '
      '(heat bumped, like memory_recall):');
  for (final entry in entries) {
    terminal.writeln(_memoryLine(entry));
  }
}

void _show(Terminal terminal, MemoryStorePair stores, String idText,
    bool global) {
  final id = _id(idText);
  final entry =
      (global ? stores.global : stores.project).entry(id);
  if (entry == null) {
    terminal.writeln('no entry #$idText');
    return;
  }
  terminal.writeln('#${entry.id} [${entry.scope.name}/${entry.category.name}] '
      'recalled ${entry.recallCount}x');
  terminal.writeln(entry.text);
  terminal.writeln('  created ${entry.createdAt.toUtc().toIso8601String()} · '
      'updated ${entry.updatedAt.toUtc().toIso8601String()} '
      'by ${entry.updatedBy}');
}

void _remember(Terminal terminal, MemoryStorePair stores, String text,
    MemoryCategory category, bool global) {
  if (text.trim().isEmpty) {
    throw const FormatException('remember text must not be empty');
  }
  final entry = (global ? stores.global : stores.project)
      .remember(text, category: category, updatedBy: 'human');
  terminal.writeln(_memoryLine(entry, textWidth: 200));
}

void _forget(Terminal terminal, MemoryStorePair stores, String idText,
    bool global) {
  final id = _id(idText);
  final deleted = (global ? stores.global : stores.project).forget(id);
  if (deleted == null) {
    terminal.writeln('no entry #$idText');
    return;
  }
  terminal.writeln('forgot ${_memoryLine(deleted, textWidth: 200)}');
}

void _promote(Terminal terminal, MemoryStorePair stores, String idText) {
  // The CLI's path, unchanged: promotion is manual only (issue 94) —
  // copy to global, delete from project.
  final id = _id(idText);
  final entry = stores.project.entry(id);
  if (entry == null) {
    terminal.writeln('no project entry #$idText to promote');
    return;
  }
  final promoted = stores.global
      .remember(entry.text, category: entry.category, updatedBy: 'promote');
  stores.project.forget(id);
  terminal.writeln('promoted #${entry.id} -> global #${promoted.id}: '
      '${_oneLine(entry.text, 200)}');
}

void _stats(Terminal terminal, MemoryStorePair stores,
    AnswerCacheStats? Function()? readCacheStats) {
  for (final store in [stores.project, stores.global]) {
    final stats = store.stats();
    final byCategory = (stats['byCategory'] as Map).cast<String, int>();
    terminal.writeln('${stats['scope']} tier — ${stats['entries']} entries'
        '${byCategory.isEmpty ? '' : ' (${byCategory.entries.map((e) => '${e.value} ${e.key}').join(', ')})'} · '
        'recalls served ${stats['recalls']}');
  }
  final cache = readCacheStats?.call();
  if (cache == null) {
    terminal.writeln('answer cache: telemetry is per-session (served/'
        'accepted/declined ride the session process; no memory plugin is '
        'attached to this one)');
    return;
  }
  terminal.writeln('answer cache (this session): '
      '${cache.served} served · ${cache.accepted} accepted · '
      '${cache.declined} declined · ${cache.staleDropped} stale dropped · '
      '~${cache.estimatedTokensSaved} tokens saved');
}

int _id(String text) {
  final id = int.tryParse(text);
  if (id == null || id < 1) {
    throw FormatException('"$text" is not an entry id');
  }
  return id;
}

/// Completion: subcommands and category names (the two vocabularies),
/// plus the flags once the word starts with `--`.
List<String> _complete(String prefix) {
  if (prefix.startsWith('--')) {
    return ['--category', '--global']
        .where((flag) => flag.startsWith(prefix))
        .toList();
  }
  return [
    ...memorySubcommands,
    for (final category in MemoryCategory.values) category.name,
  ].where((word) => word.startsWith(prefix)).toList();
}

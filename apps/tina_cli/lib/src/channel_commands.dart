/// The `tina channel` subcommands: list / read / say / status.
///
/// Routed from `runCli` before the main flag schema (the channel
/// surface is a subcommand tree, like `tina plugin`). A group chat
/// belongs to one session, so the commands default to the CURRENT
/// session's chat (the workspace's most recently active session); an
/// explicit `--session ID` inspects another session's chat, read-only.
/// This is the fallback path for a human at a terminal — in-session,
/// the channel pane is the primary input — and for scripting (`--db`
/// points at a store file directly).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina_persistence/tina_persistence.dart';

const _usage = 'usage: tina channel <list|read|say|status> [args]\n'
    '  tina channel list\n'
    '  tina channel read CHANNEL [--limit N] [--since ID|TIMESTAMP]\n'
    '  tina channel say CHANNEL TEXT... [--as NAME]\n'
    '  tina channel status [CHANNEL] [--as NAME] \\\n'
    '      [--set working|idle|done] [--summary TEXT]\n'
    'options: --cwd DIR (workspace, default .),\n'
    '         --session ID (another session\'s chat, read-only),\n'
    '         --db FILE (store file override)';

/// Routes a `tina channel ...` invocation. Returns null when [args] is
/// not a channel subcommand (the caller falls through to the main CLI).
Future<int?> runChannelSubcommand(List<String> args) async {
  if (args.isEmpty || args.first != 'channel') return null;
  final rest = args.skip(1).toList();
  final command = rest.isEmpty ? 'help' : rest.first;

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

  // Help needs no store; everything else resolves a session chat.
  if (command == 'help' || command == '--help' || command == '-h') {
    stdout.writeln(_usage);
    return 0;
  }
  final resolution = _resolveStore(workspace, flags['db'], flags['session']);
  if (resolution is _UsageFailure) {
    stderr.writeln('tina channel: ${resolution.message}');
    stderr.writeln(_usage);
    return 64;
  }
  final scope = resolution as _StoreScope;
  final storePath = scope.path;

  ChannelStoreApi openStore() {
    File(storePath).parent.createSync(recursive: true);
    return SqliteChannelStore.open(storePath);
  }

  String? refuseReadOnly() => scope.readOnly
      ? 'session "${flags['session']}" is not the current session — '
          'its chat is read-only here (read and list only)'
      : null;

  switch (command) {
    case 'list':
      return _list(openStore);
    case 'read':
      if (positional.isEmpty) return _usageError('read needs a channel');
      return _read(openStore, positional.first, flags);
    case 'say':
      if (positional.length < 2) {
        return _usageError('say needs a channel and a message');
      }
      final refused = refuseReadOnly();
      if (refused != null) return _usageError(refused);
      return _say(openStore, positional.first, positional.skip(1).join(' '),
          flags['as'] ?? 'user');
    case 'status':
      // Only --set writes; a status listing is always allowed.
      final refused = flags['set'] != null ? refuseReadOnly() : null;
      if (refused != null) return _usageError(refused);
      return _status(openStore,
          channel: positional.isEmpty ? null : positional.first,
          asName: flags['as'] ?? 'user',
          set: flags['set'],
          summary: flags['summary']);
    case 'help':
    case '--help':
    case '-h':
      return 0; // handled before store resolution
    default:
      stderr.writeln('tina channel: unknown subcommand "$command"');
      stderr.writeln(_usage);
      return 64;
  }
}

/// The store file a command should talk to. `--db` wins (raw override,
/// writable — scripting); otherwise the session chat files under
/// `.tina/channels/`: `--session` picks one (read-only unless it is
/// also the current session), no flag means the workspace's current
/// (most recently active) session, writable.
Object _resolveStore(String workspace, String? dbFlag, String? sessionFlag) {
  if (dbFlag != null && dbFlag.isNotEmpty) return _StoreScope(dbFlag, false);
  final sessionsPath = p.join(workspace, '.tina', 'sessions.db');
  if (!File(sessionsPath).existsSync()) {
    return _UsageFailure('a chat belongs to a session, and this workspace '
        'has no session store ($sessionsPath). Start a session, or pass '
        '--session ID or --db FILE.');
  }
  final sessions = SessionStore.open(sessionsPath);
  final List<StoredSession> listed;
  try {
    listed = sessions.list();
  } finally {
    sessions.close();
  }
  if (listed.isEmpty) {
    return _UsageFailure('no sessions recorded in $sessionsPath');
  }
  StoredSession latest = listed.first;
  for (final candidate in listed.skip(1)) {
    if (candidate.lastActivityKey > latest.lastActivityKey ||
        (candidate.lastActivityKey == latest.lastActivityKey &&
            candidate.registryKey > latest.registryKey)) {
      latest = candidate;
    }
  }
  if (sessionFlag != null && sessionFlag.isNotEmpty) {
    final known = listed.any((s) => s.id == sessionFlag);
    if (!known) {
      return _UsageFailure('unknown session id "$sessionFlag"');
    }
    return _StoreScope(defaultChannelStorePath(workspace, sessionFlag),
        sessionFlag != latest.id);
  }
  return _StoreScope(defaultChannelStorePath(workspace, latest.id), false);
}

final class _StoreScope {
  const _StoreScope(this.path, this.readOnly);
  final String path;
  final bool readOnly;
}

final class _UsageFailure {
  const _UsageFailure(this.message);
  final String message;
}

int _usageError(String problem) {
  stderr.writeln('tina channel: $problem');
  stderr.writeln(_usage);
  return 64;
}

int _list(ChannelStoreApi Function() open) {
  final store = open();
  try {
    final channels = store.listChannels();
    if (channels.isEmpty) {
      stdout.writeln('no channels');
      return 0;
    }
    for (final channel in channels) {
      stdout.writeln('${channel.name.padRight(20)} '
          '${channel.messages.toString().padLeft(5)} messages '
          '${channel.members.toString().padLeft(3)} members '
          '${channel.lastMessageAt?.toLocal() ?? ''}');
    }
    return 0;
  } on Object catch (e) {
    stderr.writeln('tina channel: $e');
    return 65;
  } finally {
    store.close();
  }
}

int _read(ChannelStoreApi Function() open, String channel,
    Map<String, String> flags) {
  final store = open();
  try {
    final normalized = normalizeChannelName(channel);
    final limit = int.tryParse(flags['limit'] ?? '') ?? 50;
    if (limit < 1 || limit > 200) return _usageError('limit must be 1-200');
    int? sinceId;
    DateTime? sinceTime;
    final since = flags['since'];
    if (since != null) {
      sinceId = int.tryParse(since);
      if (sinceId == null) {
        sinceTime = DateTime.tryParse(since)?.toUtc();
        if (sinceTime == null) {
          return _usageError('since must be a message id or timestamp');
        }
      }
    }
    stdout.writeln(renderChannelRead(store, normalized,
        messages: store.read(normalized,
            sinceId: sinceId, sinceTime: sinceTime, limit: limit),
        sinceId: sinceId,
        sinceTime: sinceTime));
    return 0;
  } on Object catch (e) {
    stderr.writeln('tina channel: $e');
    return 65;
  } finally {
    store.close();
  }
}

int _say(ChannelStoreApi Function() open, String channel, String text,
    String asName) {
  final store = open();
  try {
    final normalized = normalizeChannelName(channel);
    if (text.trim().isEmpty) return _usageError('message is empty');
    final posted = store.post(normalized,
        sender: asName, text: text, mentions: parseMentions(text));
    stdout.writeln('posted $normalized as $asName (id ${posted.id})');
    return 0;
  } on Object catch (e) {
    stderr.writeln('tina channel: $e');
    return 65;
  } finally {
    store.close();
  }
}

int _status(ChannelStoreApi Function() open,
    {String? channel, required String asName, String? set, String? summary}) {
  final store = open();
  try {
    if (set == null) {
      final channels = channel == null
          ? store.listChannels().map((c) => c.name).toList()
          : [normalizeChannelName(channel)];
      if (channels.isEmpty) {
        stdout.writeln('no channels');
        return 0;
      }
      for (final name in channels) {
        stdout.writeln(name);
        final members = store.members(name);
        if (members.isEmpty) {
          stdout.writeln('  nobody present');
          continue;
        }
        for (final member in members) {
          final seen =
              member.lastSeen.toLocal().toString().substring(11, 19);
          stdout.writeln('  ${member.name} (${member.role}) '
              '${member.status}'
              '${member.summary == null ? '' : ' — ${member.summary}'}'
              ' · seen $seen');
        }
      }
      return 0;
    }
    if (channel == null) {
      return _usageError('setting a status needs a channel');
    }
    if (!['working', 'idle', 'done'].contains(set)) {
      return _usageError('status must be working, idle or done');
    }
    final normalized = normalizeChannelName(channel);
    store.setMember(normalized, asName,
        status: set, role: 'user', summary: summary);
    stdout.writeln('presence set: $asName is $set in $normalized');
    return 0;
  } on Object catch (e) {
    stderr.writeln('tina channel: $e');
    return 65;
  } finally {
    store.close();
  }
}

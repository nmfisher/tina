/// The `tina channel` subcommands: list / read / say / status.
///
/// Routed from `runCli` before the main flag schema (the channel
/// surface is a subcommand tree, like `tina plugin`). This is the
/// Phase 1 acceptance path: a human inspects the workspace's shared
/// agent channels and posts from a terminal. It opens its own store
/// connection to `.tina/channel.db` under the workspace.
library;

import 'dart:io';

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';

const _usage = 'usage: tina channel <list|read|say|status> [args]\n'
    '  tina channel list\n'
    '  tina channel read CHANNEL [--limit N] [--since ID|TIMESTAMP]\n'
    '  tina channel say CHANNEL TEXT... [--as NAME]\n'
    '  tina channel status [CHANNEL] [--as NAME] \\\n'
    '      [--set working|idle|done] [--summary TEXT]\n'
    'options: --cwd DIR (workspace, default .), --db FILE (store override)';

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
  final dbFlag = flags['db'];
  final storePath = dbFlag ?? defaultChannelStorePath(workspace);

  ChannelStoreApi openStore() {
    File(storePath).parent.createSync(recursive: true);
    return SqliteChannelStore.open(storePath);
  }

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
      return _say(openStore, positional.first, positional.skip(1).join(' '),
          flags['as'] ?? 'user');
    case 'status':
      return _status(openStore,
          channel: positional.isEmpty ? null : positional.first,
          asName: flags['as'] ?? 'user',
          set: flags['set'],
          summary: flags['summary']);
    case 'help':
    case '--help':
    case '-h':
      stdout.writeln(_usage);
      return 0;
    default:
      stderr.writeln('tina channel: unknown subcommand "$command"');
      stderr.writeln(_usage);
      return 64;
  }
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
            sinceId: sinceId, sinceTime: sinceTime, limit: limit)));
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

import 'dart:io';

import 'sqlite_channel_store.dart';

/// Opens (creating parents) this session's chat store:
/// `.tina/channels/<session-id>.db` under [workspace].
ChannelStoreApi openDefaultChannelStore(String workspace, String sessionId) {
  final path = defaultChannelStorePath(workspace, sessionId);
  try {
    File(path).parent.createSync(recursive: true);
  } on Object catch (e) {
    throw ChannelStoreException('cannot create $path', e);
  }
  return SqliteChannelStore.open(path);
}

/// Whether this session's chat store file already exists — the
/// opt-in/resume probe. Never creates anything.
bool defaultChannelStoreExists(String workspace, String sessionId) =>
    File(defaultChannelStorePath(workspace, sessionId)).existsSync();

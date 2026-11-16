import 'dart:io';

import 'sqlite_channel_store.dart';

/// Opens (creating parents) `.tina/channel.db` under [workspace].
ChannelStoreApi openDefaultChannelStore(String workspace) {
  final path = defaultChannelStorePath(workspace);
  try {
    File(path).parent.createSync(recursive: true);
  } on Object catch (e) {
    throw ChannelStoreException('cannot create $path', e);
  }
  return SqliteChannelStore.open(path);
}

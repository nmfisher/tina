/// Platforms without `dart:io` have no default store location; the
/// composition root injects an implementation instead.
Never openDefaultChannelStore(String workspace) => throw UnsupportedError(
    'no default channel store on this platform; inject one');

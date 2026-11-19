Never openDefaultChannelStore(String workspace, String sessionId) =>
    throw UnsupportedError(
        'channel stores need dart:io; a wasm composition root injects '
        'its own implementation through the opener seam');

/// Same conditional-seam contract as the opener: platforms without
/// `dart:io` have no files to probe.
Never defaultChannelStoreExists(String workspace, String sessionId) =>
    throw UnsupportedError(
        'channel stores need dart:io; a wasm composition root injects '
        'its own implementation through the opener seam');

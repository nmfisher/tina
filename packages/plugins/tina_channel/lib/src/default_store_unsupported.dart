Never openDefaultChannelStore(String workspace, String sessionId) =>
    throw UnsupportedError(
        'channel stores need dart:io; a wasm composition root injects '
        'its own implementation through the opener seam');

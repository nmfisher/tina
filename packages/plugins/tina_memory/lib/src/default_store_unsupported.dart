Never openDefaultMemoryStores(String workspace,
        {Map<String, String>? environment}) =>
    throw UnsupportedError(
        'memory stores need dart:io; a wasm composition root injects '
        'its own implementation through the opener seam');

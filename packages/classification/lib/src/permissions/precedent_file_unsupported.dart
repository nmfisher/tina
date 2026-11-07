/// The no-`dart:io` primitives: a wasm composition root does not
/// construct file-backed precedent stores; reaching these is a wiring
/// bug, so they fail loudly.
Never _fail() =>
    throw UnsupportedError('no file-backed precedents on this platform');

List<String> precedentReadLines(String path) => _fail();

void precedentDelete(String path) => _fail();

void precedentWriteAtomic(String path, String contents) => _fail();

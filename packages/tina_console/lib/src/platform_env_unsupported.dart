/// The no-`dart:io` platform seam (wasm compilation): the environment is
/// empty, ANSI stays optimistic (the host owns a real terminal) and debug
/// trace writes are dropped (the host owns the filesystem).
library;

/// The value of [name] in the process environment, or null.
String? platformEnv(String name) => null;

/// Whether [name] appears in the process environment.
bool platformEnvHas(String name) => false;

/// Whether stdout accepts ANSI escape sequences. The wasm guest cannot
/// probe the host terminal; the composition root forces ANSI capability
/// explicitly, so this only shapes [AnsiCapable.detect].
bool platformStdoutSupportsAnsi() => true;

/// Append [contents] to the file at [path]. Not part of the wasm guest
/// contract: the host owns the filesystem, so debug traces drop.
void platformAppendFile(String path, String contents) {}

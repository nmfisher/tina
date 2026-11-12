// ignore_for_file: type=warning

/// The host's tty authority: it owns the real terminal, so window size is a
/// live answer (re-supplied on resize), not an env snapshot.
abstract interface class Tty {
  (int, int) getSize();
}

/// The guest-to-host failure channel (spike finding 4): a guest Dart
/// exception that would otherwise kill the guest task and park the host's
/// `run` call forever calls `fail` first (from the top-level zone guard),
/// then invokes the WASI `exit` import as the structural backstop. The host
/// records the message, stops waiting, restores the terminal and reports
/// `guest crashed: <message>` with a non-zero exit.
abstract interface class Crash {
  void fail({required String message});
}

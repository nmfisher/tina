// ignore_for_file: type=warning

/// The host's tty authority for the guest (Option 2 spike): it owns the real
/// terminal, so window size is a live answer (re-supplied on resize), not an
/// env snapshot.
abstract interface class Tty {
  (int, int) getSize();
}

/// Human identity for the channel pane: the name the person at the
/// terminal posts under. Agent identity is a generated shortcode; the
/// human's name comes from configuration — an explicit environment
/// override first, otherwise the OS username, sanitized into something
/// a sender label and an `@mention` can carry. Like agent identity,
/// the derivation is pure (the assembly passes the environment map)
/// and decided at the composition seam, never inside the tools or the
/// store.
library;

/// The explicit-identity override from an environment mapping (the
/// composition root passes `Platform.environment`): a nonempty
/// `TINA_HUMAN_NAME` wins verbatim, everything else means derive.
String? humanNameFromEnvironment(Map<String, String> environment) {
  final value = environment['TINA_HUMAN_NAME']?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Sanitizes a raw OS username into a channel sender name: lowercase,
/// keep `[a-z0-9_.-]` (the mention grammar's name characters), collapse
/// every other run to `-`, strip leading/trailing `-`, cap at 32. An
/// empty result (empty input, or nothing survived) falls back to
/// `user` — the CLI's historic default sender.
String sanitizeHumanName(String raw) {
  final lowered = raw.toLowerCase().trim();
  final collapsed = lowered.replaceAll(RegExp(r'[^a-z0-9_.-]+'), '-');
  var name = collapsed.replaceAll(RegExp(r'^-+|-+$'), '');
  if (name.length > 32) name = name.substring(0, 32);
  return name.isEmpty ? 'user' : name;
}

/// The session's human name: `TINA_HUMAN_NAME` verbatim when set,
/// otherwise the OS username (`USER`, `LOGNAME`, `USERNAME` — first
/// hit) sanitized, otherwise `user`. Pure function of the environment,
/// so it is stable within a session by construction.
String defaultHumanName(Map<String, String> environment) =>
    humanNameFromEnvironment(environment) ??
    sanitizeHumanName(environment['USER'] ??
        environment['LOGNAME'] ??
        environment['USERNAME'] ??
        '');

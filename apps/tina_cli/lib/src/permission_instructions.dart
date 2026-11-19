/// The project's permission-preference instructions: the
/// `instructions` field of `.tina/permissions.json`, read by the
/// classifier wiring and the settings management alike. Kept in its
/// own module so runtime plugin construction can import it without
/// reaching any presentation package.
library;

import 'dart:convert';
import 'dart:io';

/// The project's permission-preference instructions from
/// `.tina/permissions.json` (top-level `instructions`, next to
/// `grants`), or null when absent, empty or damaged — the session's
/// classifier-instruction setting stays the fallback, and a damaged
/// file is PathGrants' error to report.
String? readProjectPermissionInstructions(String workspace) {
  try {
    final file = File('$workspace/.tina/permissions.json');
    if (!file.existsSync()) return null;
    final document = jsonDecode(file.readAsStringSync());
    if (document is! Map) return null;
    final instructions = document['instructions'];
    if (instructions is! String) return null;
    final trimmed = instructions.trim();
    return trimmed.isEmpty ? null : trimmed;
  } on Object {
    return null;
  }
}

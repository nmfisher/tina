/// The project's permission-preference instructions: the
/// `instructions` field of `.tina/permissions.json`, read by the
/// classifier wiring and the settings management alike. Kept in its
/// own module so runtime plugin construction can import it without
/// reaching any presentation package.
///
/// Reads go through the [AppIo] seam (commit 27): under wasm the
/// workspace preopen answers, not a native `dart:io` file — the read
/// is wasm-aware wherever the settings path opens from.
library;

import 'dart:convert';

import 'app_io.dart';

/// The project's permission-preference instructions from
/// `.tina/permissions.json` (top-level `instructions`, next to
/// `grants`), or null when absent, empty or damaged — the session's
/// classifier-instruction setting stays the fallback, and a damaged
/// file is PathGrants' error to report.
String? readProjectPermissionInstructions(String workspace, {AppIo? io}) {
  try {
    final raw = (io ?? defaultAppIo())
        .readTextIfExists('$workspace/.tina/permissions.json');
    if (raw == null) return null;
    final document = jsonDecode(raw);
    if (document is! Map) return null;
    final instructions = document['instructions'];
    if (instructions is! String) return null;
    final trimmed = instructions.trim();
    return trimmed.isEmpty ? null : trimmed;
  } on Object {
    return null;
  }
}

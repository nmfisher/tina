import 'dart:io';

import 'package:path/path.dart' as p;

/// The tina user-data directory: `$HOME/.tina` (or `%USERPROFILE%` on
/// Windows), falling back to the current directory if neither is set. Takes an
/// env map rather than reading [Platform] directly so callers that already hold
/// one (e.g. [PlatformEnvironment.env], or [Platform.environment] at the entry
/// point) don't re-derive it — the three-way fallback lived in three places
/// before this (sessions, logging, user config) and had begun to drift.
///
/// The directory is created lazily by its users (the session store, logging);
/// this just resolves the path.
Directory tinaDirFromEnv(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
  return Directory(p.join(home, '.tina'));
}

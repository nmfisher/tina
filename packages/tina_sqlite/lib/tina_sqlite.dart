/// tina_sqlite — the one SQLite seam for tina: a versioned open-or-create
/// step, a generic append-only entry log, a generic key-value table, and
/// the plain-file twin for the entry log (JSON Lines). Feature stores own
/// their schemas and use these shared persistence primitives.
library;

export 'src/database.dart';
export 'src/entry_log.dart';
export 'src/json_lines.dart';
export 'src/kv.dart';
export 'src/poison_pill.dart';

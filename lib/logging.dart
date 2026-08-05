import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'package:tina_engine/tina_engine.dart';

/// App-wide logging bootstrap. The single seam between the rest of the app and
/// `package:logging`: callers grab a named [Logger] (`Logger('tina.tools.bash')`,
/// etc.) and write to it; this module owns the root level, the file sink, the
/// line format, and stderr mirroring. See the logging plan
/// (`crystalline-wiggling-parnas.md`) for the level policy.

StreamSubscription<LogRecord>? _sub;
IOSink? _sink;
bool _initialized = false;

/// Configure the root logger. Call once at startup, after config is parsed.
///
/// - [level]: minimum level to record (default [Level.INFO]).
/// - [logFile]: file to append to (default `~/.tina/tina.log`).
/// - [mirrorToStderr]: also write each record to stderr (default: only when
///   stdin is not a TTY, i.e. non-interactive / `--prompt` runs).
///
/// Idempotent: a second call is a no-op, so re-entry or tests don't attach a
/// second listener (which would double every line) or leak the prior file
/// handle. Tear down with [closeLogging].
void initLogging({
  Level level = Level.INFO,
  File? logFile,
  bool? mirrorToStderr,
}) {
  if (_initialized) return;
  _initialized = true;
  Logger.root.level = level;
  final file = logFile ?? _defaultLogFile();
  // ~/.tina may not exist yet (the session store creates it lazily), and
  // openWrite does not create parent dirs. A log file must NEVER crash the
  // app: openWrite opens asynchronously, so a failure (missing/unwritable
  // dir, read-only mount) would otherwise surface as an unhandled zone error
  // mid-TUI and kill the process without terminal teardown. Degrade to
  // stderr-only logging instead.
  try {
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final sink = file.openWrite(mode: FileMode.append);
    // The open (and later writes) fail asynchronously on sink.done — handle
    // that by dropping the file sink, never by dying. Attached synchronously
    // after openWrite returns, so the error can't escape before this handler.
    sink.done.catchError((Object _) {
      _sink = null;
    });
    _sink = sink;
  } on FileSystemException catch (e) {
    _sink = null;
    stderr.writeln('tina: warning: cannot open log file ${file.path}: $e');
  }
  _sub = Logger.root.onRecord.listen((r) {
    final line = _format(r);
    _sink?.writeln(line);
    if (mirrorToStderr ?? _isNonInteractive) stderr.writeln(line);
  });
}

/// Flush and close the file sink and drop the subscription. Call from the
/// shutdown path so buffered records survive a clean exit — the exact scenario
/// logging exists for. Idempotent.
Future<void> closeLogging() async {
  await _sub?.cancel();
  _sub = null;
  await _sink?.flush();
  await _sink?.close();
  _sink = null;
  _initialized = false;
}

bool get _isNonInteractive => stdioType(stdin) != StdioType.terminal;

String _format(LogRecord r) =>
    '${r.time.toIso8601String()} [${r.level.name}] ${r.loggerName}: ${r.message}'
    '${r.error != null ? '\n  ${r.error}' : ''}'
    '${r.stackTrace != null ? '\n${r.stackTrace}' : ''}';

File _defaultLogFile() =>
    File(p.join(tinaDirFromEnv(Platform.environment).path, 'tina.log'));

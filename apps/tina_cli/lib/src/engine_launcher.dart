/// The engine launcher (Option 1 Phase B): spawns an engine process that
/// speaks the pipes protocol on stdio — the packaged `tina-wasm-host`, a
/// dev engine binary, or any command with the same contract — and wires
/// its streams into a [PipesConnection] for the front end.
///
/// The wasm-host invocation convention: the workspace and the global
/// config tree ride WASI preopens (`.` and `config`), the engine's
/// knobs ride WASI environment variables (`TINA_ENGINE_*`), and provider
/// endpoints/credentials are forwarded explicitly (`TINA_LLM_ENDPOINT`,
/// `ANTHROPIC_API_KEY`) — a sandboxed guest sees only what the launcher
/// passes, never the host environment.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'pipes.dart' show decodePipesLines;
import 'pipes_connection.dart' show PipesConnection;

/// One spawned engine process. [start] launches it and begins decoding;
/// [ready] completes with the connection once the engine's `ready` event
/// arrives — or errors with the captured stderr tail when the process
/// dies first.
final class EngineProcess {
  EngineProcess._(this._process, this._stderr);

  final Process _process;
  final _StderrTail _stderr;
  String? _bootTiming;

  /// Completes when the host's stderr has fully drained (bounded).
  late final Future<void> _stderrDone;
  final _exited = Completer<int>();
  var _stdinOpen = true;
  var _stopAsked = false;
  late final PipesConnection _connection;
  late final Future<PipesConnection> _ready;

  /// The connection once [ready] completed.
  Future<PipesConnection> get ready => _ready;

  PipesConnection get connection => _connection;

  /// The process exit code — completed after [stop] or an engine exit.
  Future<int> get exitCode => _exited.future;

  /// The captured stderr tail, for diagnostics on abnormal exits.
  String get stderrTail => _stderr.text;

  /// The host's most recent boot-timing line ('wasm boot: compiled from
  /// bytes (…)' or 'wasm boot: deserialized cache hit (…)'), read off
  /// its stderr; null before the host printed one. Meaningful once
  /// [ready] completes: the host instantiates the component before the
  /// engine's `ready` event, so the line has landed by then.
  String? get bootTiming => _bootTiming;

  void _noteStderrLine(String line) {
    _stderr.write('$line\n');
    // The host's one boot-timing line per launch ('wasm boot: …',
    // compile vs deserialize): surfaced as the session's startup
    // notice once the engine reports ready.
    if (line.startsWith('wasm boot: ')) _bootTiming = line;
  }

  /// Spawns [argv] (pipes protocol on stdio). [onEvent] observes decoded
  /// engine events as diagnostics; it can never alter the protocol.
  static Future<EngineProcess> start(
    List<String> argv, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    if (argv.isEmpty) throw ArgumentError('engine argv is empty');
    final stderr = _StderrTail(8 << 10);
    final process = await Process.start(
      argv.first,
      argv.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment.isEmpty ? null : environment,
    );
    final handle = EngineProcess._(process, stderr);
    handle._stderrDone = process.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(handle._noteStderrLine, cancelOnError: false)
        .asFuture<void>()
        // A closed stderr must never hang the ready-failure path; the
        // process is dead by then, so the close is imminent — bounded
        // only out of caution.
        .timeout(const Duration(seconds: 2));
    unawaited(handle._stderrDone.catchError((Object _) {}));
    unawaited(process.exitCode.then((code) {
      if (!handle._exited.isCompleted) handle._exited.complete(code);
    }));
    // The launcher drains stdout for the process's whole life, behind a
    // broadcast controller: a front end that closes its connection cancels
    // its subscription, but the pipe must stay drained or the host dies on
    // EPIPE writing its goodbye.
    final events = StreamController<Map<String, dynamic>>.broadcast();
    unawaited(
        decodePipesLines(process.stdout)
            .map((line) => _decode(line, stderr))
            .where((event) => event != null)
            .cast<Map<String, dynamic>>()
            .listen(events.add, cancelOnError: false, onDone: () {
          if (!events.isClosed) unawaited(events.close());
        }).asFuture<void>());
    unawaited(process.exitCode.then((_) {
      if (!events.isClosed) unawaited(events.close());
    }));
    final connection = PipesConnection(
      send: handle._sendLine,
      events: onEvent == null
          ? events.stream
          : events.stream.map((event) {
              try {
                onEvent(event);
              } catch (_) {/* diagnostics never break the protocol */}
              return event;
            }),
    );
    handle._connection = connection;
    handle._ready = connection.started.then((_) => connection).catchError(
        (Object error) async {
          // Wait for the stderr drain before freezing the tail into the
          // error: a dying host's diagnostic lines race the stdout EOF
          // that triggers this path, and callers (the launch guard)
          // classify on the tail's contents.
          try {
            await handle._stderrDone;
          } catch (_) {/* the tail is best-effort diagnostics */}
          throw StateError('$error\n${stderr.text}');
        });
    return handle;
  }

  /// Asks the engine to shut down, waits briefly, then terminates. Safe
  /// after the connection is closed: the process is stopped directly.
  Future<void> stop({Duration grace = const Duration(seconds: 5)}) async {
    if (_stopAsked) return;
    _stopAsked = true;
    _sendLine(const {'op': 'shutdown'});
    var exited = false;
    try {
      await _process.exitCode.timeout(grace);
      exited = true;
    } on TimeoutException {
      // Still running: fall through to termination.
    }
    if (!exited) kill();
    await _process.exitCode;
  }

  /// Immediate termination — startup failures and abandoned sessions.
  void kill() {
    _stopAsked = true;
    if (!_exited.isCompleted) _process.kill(ProcessSignal.sigkill);
  }

  void _sendLine(Object line) {
    if (!_stdinOpen) return;
    try {
      _process.stdin.add(utf8.encode('${jsonEncode(line)}\n'));
    } catch (_) {
      _stdinOpen = false;
    }
  }

  static Map<String, dynamic>? _decode(String line, _StderrTail stderr) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      stderr.write('engine sent a non-JSON line: $trimmed\n');
      return null;
    }
  }
}

/// A bounded stderr tail for error messages.
final class _StderrTail {
  _StderrTail(this.capacity);
  final int capacity;
  var _text = '';

  void write(String text) {
    _text += text;
    if (_text.length > capacity) {
      _text = _text.substring(_text.length - capacity);
    }
  }

  String get text => _text;
}


/// The runner snapshots only the named config file and grants only the
/// named session file. It forwards provider credentials from its process
/// environment. The workspace is the process's working directory.
List<String> wasmEngineArgv({
  required String hostPath,
  required String workingDirectory,
  required String configPath,
  String? storePath,
  String? resumeSessionId,
  required bool yolo,
  List<String> extraArgs = const [],
  /// The active registry plugin's cached component + the host-accepted
  /// grants (design doc section 6): appended as the existing
  /// `--plugin-component` / `--plugin-grant` mount flags.
  String? pluginComponent,
  List<String> pluginGrants = const [],

  /// The active plugin artifact's provenance (origin/hash/builtAt),
  /// forwarded so the engine's /plugins status can report it.
  String? pluginOrigin,
  String? pluginHash,
  String? pluginBuilt,
  /// The compiled-component cache directory (commit 29): the host
  /// serializes the compiled engine there keyed by the artifact bytes'
  /// hash and deserializes on later launches instead of recompiling.
  /// Null keeps the flag off (compile on every launch, as before).
  String? componentCache,
}) {
  String absolute(String path) => p.normalize(p.absolute(workingDirectory, path));
  final argv = <String>[hostPath]
    ..add('--headless')
    ..add('--config-file=${absolute(configPath)}');
  argv.add('--env=TINA_ENGINE_YOLO=${yolo ? '1' : '0'}');
  if (storePath != null) {
    argv.add('--store-file=${absolute(storePath)}');
  }
  if (resumeSessionId != null) {
    argv.add('--env=TINA_ENGINE_RESUME=$resumeSessionId');
  }
  if (pluginComponent != null) {
    argv.add('--plugin-component=$pluginComponent');
    if (pluginOrigin != null) {
      argv.add('--env=TINA_ENGINE_PLUGIN_ORIGIN=$pluginOrigin');
      if (pluginHash != null) {
        argv.add('--env=TINA_ENGINE_PLUGIN_HASH=$pluginHash');
      }
      if (pluginBuilt != null) {
        argv.add('--env=TINA_ENGINE_PLUGIN_BUILT=$pluginBuilt');
      }
    }
    // Only grants the running host accepts are mounted; recorded grants
    // the host does not know are reported by the installer instead.
    for (final grant in pluginGrants) {
      argv.add('--plugin-grant=$grant');
    }
  }
  if (componentCache != null) {
    argv.add('--component-cache=$componentCache');
  }
  argv.addAll(extraArgs.where((flag) => flag != '--headless' && flag != '--pipes'));
  return argv;
}

/// The global compiled-component cache directory: `~/.cache/tina/
/// wasm-components`. Components are workspace-independent, so one
/// global directory hits across projects; the host keys entries by the
/// artifact bytes' hash, so any artifact change recompiles
/// automatically and tina never invalidates anything itself.
String wasmComponentCacheDir({Map<String, String>? environment}) {
  final home = (environment ?? Platform.environment)['HOME'] ?? '.';
  return '$home/.cache/tina/wasm-components';
}

/// Preflights the cache directory: creates it and proves it writable
/// with a probe file. Never throws — an unusable directory means the
/// cache stays off (launch without the flag) and carries a one-line
/// notice for the session's startup surface.
({String? dir, String? notice}) prepareWasmComponentCache(
    {Map<String, String>? environment}) {
  final dir = wasmComponentCacheDir(environment: environment);
  try {
    Directory(dir).createSync(recursive: true);
    final probe = File('$dir${Platform.pathSeparator}.write-probe');
    probe.writeAsStringSync('probe', flush: true);
    probe.deleteSync();
    return (dir: dir, notice: null);
  } on Object catch (error) {
    return (
      dir: null,
      notice: 'wasm component cache unavailable ($dir): $error — '
          'launching without it'
    );
  }
}

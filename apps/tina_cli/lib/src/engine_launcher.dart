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
import 'package:tina_capability/tina_capability.dart';
import 'package:tina_tools/tina_tools.dart'
    show CommandApprovalStore, CommandApprovalScope;

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
    unawaited(process.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderr.write, cancelOnError: false)
        .asFuture<void>());
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
    handle._ready = connection.started
        .then((_) => connection)
        .catchError((Object error) => throw StateError('$error\n${stderr.text}'));
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

/// Canonical path like the stores use (symlinks resolved); falls back to
/// the normalized absolute path when the target does not exist yet.
String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return File(absolute).resolveSymbolicLinksSync();
  } on FileSystemException {
    return absolute;
  }
}

/// Reads the standing grants the approvals stores hold for [workspace]:
/// directory settings from `permissions.json` and command/network grants
/// from `commands.json`. A missing store contributes nothing - a fresh
/// install compiles the structural-only document, byte-identical to
/// yesterday's launch surface.
CapabilityInputs readCapabilityInputs({
  required String workspace,
  required String configDir,
  required bool yolo,
  Map<String, String> environment = const {},
}) {
  final canonicalWorkspace = _canonical(workspace);
  final permissions = CommandApprovalStore(
    workspace: canonicalWorkspace,
    file: File(p.join(configDir, 'approvals', 'permissions.json')),
  );
  final commands = CommandApprovalStore(
    workspace: canonicalWorkspace,
    file: File(p.join(configDir, 'approvals', 'commands.json')),
  );

  List<String> settingList(String id) => [
        for (final scope in ['global', 'workspace'])
          ...?((permissions.settings(
            CommandApprovalScope.values.byName(scope),
          ))[id] as List?)
              ?.whereType<String>(),
      ];

  final rules = <CommandRuleInput>[];
  final domains = <DomainEntry>[];
  for (final entry in commands.entries) {
    final origin = 'grant:${entry['id']}';
    final pattern = entry['pattern'];
    if (pattern is String && pattern.isNotEmpty) {
      // A remembered command grant is an allow the user reviewed.
      rules.add(CommandRuleInput(
        pattern: pattern,
        verdict: CommandVerdict.allow,
        origin: origin,
      ));
    }
    if (entry['capability'] == 'network' && entry['target'] is String) {
      domains.add(DomainEntry(
        domain: entry['target'] as String,
        origin: origin,
      ));
    }
  }

  // The provider endpoints the wasm engine is allowed to reach: the
  // forwarded endpoint env and the Anthropic API when a key rides along.
  final endpoint = environment['TINA_LLM_ENDPOINT'] ??
      Platform.environment['TINA_LLM_ENDPOINT'];
  if (endpoint != null && endpoint.isNotEmpty) {
    final host = Uri.tryParse(endpoint)?.host;
    if (host != null && host.isNotEmpty) {
      domains.add(DomainEntry(domain: host, origin: 'provider:tina-llm'));
    }
  }
  if ((environment['ANTHROPIC_API_KEY'] ??
              Platform.environment['ANTHROPIC_API_KEY']) !=
          null &&
      (environment['ANTHROPIC_API_KEY'] ??
              Platform.environment['ANTHROPIC_API_KEY'])!
          .isNotEmpty) {
    domains.add(
      const DomainEntry(domain: 'api.anthropic.com', origin: 'provider:anthropic'),
    );
  }

  return CapabilityInputs(
    mode: yolo ? CapabilityMode.yolo : CapabilityMode.ask,
    workspace: canonicalWorkspace,
    configDir: _canonical(configDir),
    readDirectories: settingList('tina/tools/read_only_directories'),
    writeDirectories: settingList('tina/tools/write_directories'),
    homeCaches: settingList('tina/tools/home_caches'),
    rules: rules,
    domains: domains,
    // Protected leaves, never the config dir itself: the config tree is
    // a structural write grant (the engine persists settings through it)
    // and its approvals subtree stays a protected leaf beneath that
    // grant - the native model (masking), not a host-wall refusal.
    protectedPaths: [
      p.join(configDir, 'approvals'),
    ].map(_canonical).toSet().toList(),
  );
}

/// The tina-wasm-host invocation for one workspace: the workspace and the
/// global config tree as preopens, the engine's knobs as WASI environment
/// variables, provider endpoint and credential forwarded explicitly.
///
/// [storePath] is an absolute host path; inside the workspace it maps to
/// the guest-relative path, outside it gets its own `store` preopen.
/// [configPath] must name a `config` file — that is the default layout —
/// because the engine reads `config/config` through the preopen.
List<String> wasmEngineArgv({
  required String hostPath,
  required String workingDirectory,
  required String configPath,
  String? storePath,
  String? resumeSessionId,
  required bool yolo,
  Map<String, String> environment = const {},
  List<String> extraArgs = const [],
  String? capabilitiesPath,
}) {
  final workspace = p.normalize(p.absolute(workingDirectory));
  final config = p.normalize(p.absolute(configPath));
  if (p.basename(config) != 'config') {
    throw FormatException(
        'the wasm engine reads the global config from a `config` file in '
        'its parent directory; --config must end in /config');
  }
  final argv = <String>[hostPath];
  if (capabilitiesPath != null) {
    // The capability document carries the preopen structure (derived from
    // its directory grants at instantiation); the legacy --preopen flags
    // stay for old launchers, and old hosts bail on unknown flags, so the
    // two forms are mutually exclusive.
    argv.add('--capabilities=$capabilitiesPath');
  } else {
    argv
      ..add('--preopen=.=$workspace')
      ..add('--preopen=config=${p.dirname(config)}');
  }
  argv.add('--env=TINA_ENGINE_YOLO=${yolo ? '1' : '0'}');
  if (storePath != null) {
    final store = p.normalize(p.absolute(storePath));
    final relative = p.relative(store, from: workspace);
    final inside = !relative.startsWith('..') && !p.isAbsolute(relative);
    if (inside) {
      argv.add('--env=TINA_ENGINE_STORE=$relative');
    } else {
      if (capabilitiesPath == null) {
        argv.add('--preopen=store=${p.dirname(store)}');
      }
      argv.add('--env=TINA_ENGINE_STORE=store/${p.basename(store)}');
    }
  }
  if (resumeSessionId != null) {
    argv.add('--env=TINA_ENGINE_RESUME=$resumeSessionId');
  }
  // The provider endpoint and credential the wasm provider reads; a guest
  // sees only forwarded names, never the host environment.
  for (final name in const ['TINA_LLM_ENDPOINT', 'ANTHROPIC_API_KEY']) {
    final value = environment[name] ?? Platform.environment[name];
    if (value != null && value.isNotEmpty) argv.add('--env=$name=$value');
  }
  argv.addAll(
      environment.entries.map((entry) => '--env=${entry.key}=${entry.value}'));
  argv.addAll(extraArgs);
  return argv;
}

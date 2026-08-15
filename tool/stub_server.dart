import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Stub LLM provider server for deterministic UI sweeps.
///
/// Replays canned OpenAI-compatible `/v1/chat/completions` SSE responses so
/// tina runs with zero spend and no real model. tina connects through the
/// provider `base_url` override (a `[providers.stub]` block in `~/.tina/config`)
/// — no tina code changes are needed, because this server speaks the same wire
/// format as `OpenAiCompatibleAdapter` (see
/// `packages/tina_engine/lib/src/llm/openai_compatible.dart`).
///
/// Usage:
///
///     dart run tool/stub_server.dart --scenario normal [--port 8787]
///
/// Responses come from a scenario script (a plain text file under
/// `tool/stub/scenarios/<name>.txt`) that contains the literal SSE bytes to
/// send, plus a few `!` control directives. Same scenario + same request →
/// identical bytes, every run: the server adds nothing of its own to the
/// stream — no timestamps, no generated ids. See `tool/stub/README.md` for the
/// script format and the sweep workflow.
Future<void> main(List<String> args) async {
  var scenario = 'normal';
  var host = '127.0.0.1';
  var port = 8787;
  var scenariosDir =
      p.join(p.dirname(p.fromUri(Platform.script)), 'stub', 'scenarios');

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--scenario':
        scenario = args[++i];
      case '--host':
        host = args[++i];
      case '--port':
        port = int.parse(args[++i]);
      case '--dir':
        scenariosDir = args[++i];
      case '--help' || '-h':
        stdout.writeln('usage: dart run tool/stub_server.dart '
            '--scenario <name> [--host 127.0.0.1] [--port 8787] [--dir <scenarios-dir>]');
        exit(0);
      default:
        stderr.writeln('unknown argument: ${args[i]} (see --help)');
        exit(2);
    }
  }

  final script = ScenarioScript.load('$scenariosDir/$scenario.txt');
  final server = await StubServer.bind(host, port, script, scenarioName: scenario);
  stdout.writeln('[stub] scenario=$scenario steps=${script.steps.length} '
      'listening on http://$host:$port/v1/chat/completions');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('[stub] shutting down');
    await server.close();
    exit(0);
  });
}

/// One canned HTTP response, as a sequence of [StepAction]s replayed in order.
class Step {
  final int status;
  final List<StepAction> actions;
  Step(this.status, this.actions);
}

/// A single unit of replay: write a line, pause, or cut the connection.
sealed class StepAction {}

/// Writes [line] plus a trailing newline, then flushes.
final class WriteLine extends StepAction {
  final String line;
  WriteLine(this.line);
}

/// Sleeps before the following actions run. Pacing only — it never changes
/// the bytes on the wire.
final class Wait extends StepAction {
  final Duration duration;
  Wait(this.duration);
}

/// Destroys the socket mid-stream (mid-stream abort scenario).
final class Abort extends StepAction {}

/// A parsed scenario script: N steps, served to requests 1..N in order.
/// Requests past the last step replay the last step (a sweep task may run
/// more turns than the script spells out; the tail repeats deterministically).
class ScenarioScript {
  final List<Step> steps;
  ScenarioScript(this.steps);

  static ScenarioScript load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('[stub] scenario file not found: $path');
      exit(2);
    }
    return parse(file.readAsStringSync());
  }

  /// Parses the script format:
  ///
  /// - `# ...` comment (line must start with `#`)
  /// - `!step` — starts the next step; lines before the first `!step` are step 1
  /// - `!status <code>` — respond with this status; the step's lines become the
  ///   literal error body (no SSE framing added)
  /// - `!delay <ms>` — pause before the following lines
  /// - `!abort` — destroy the socket at this point in the stream
  /// - anything else — a literal line of the response body, sent verbatim
  static ScenarioScript parse(String text) {
    final steps = <Step>[];
    var status = 200;
    var actions = <StepAction>[];

    void endStep() {
      if (actions.isNotEmpty) steps.add(Step(status, actions));
      status = 200;
      actions = <StepAction>[];
    }

    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.startsWith('#')) continue; // full-line comment

      if (line == '!step') {
        endStep();
      } else if (line.startsWith('!status ')) {
        status = int.parse(line.substring(8).trim());
      } else if (line.startsWith('!delay ')) {
        actions.add(Wait(Duration(milliseconds: int.parse(line.substring(7).trim()))));
      } else if (line == '!abort') {
        actions.add(Abort());
      } else if (line == '!status' || line == '!delay' || line.startsWith('!')) {
        throw FormatException('unknown directive: $line');
      } else {
        actions.add(WriteLine(line));
      }
    }
    endStep();
    if (steps.isEmpty) {
      throw const FormatException('scenario script has no response lines');
    }
    return ScenarioScript(steps);
  }

  Step stepFor(int requestIndex) =>
      steps[requestIndex < steps.length ? requestIndex : steps.length - 1];
}

/// The server. Speaks just enough HTTP/1.1 by hand, on a raw [ServerSocket],
/// for two reasons dart:io's [HttpServer] can't offer:
///
/// - `!abort` must destroy the connection *after* frames have been flushed —
///   `HttpResponse.detachSocket` refuses once headers are on the wire.
/// - the response body must be exact UTF-8 bytes (latin1 `write` would mangle
///   the emoji/CJK scenarios).
///
/// Every response is sent with `Connection: close`, so there is no framing
/// state to carry between requests.
class StubServer {
  final ServerSocket _server;
  final ScenarioScript _script;
  final String _scenarioName;
  int _requestCount = 0;

  StubServer._(this._server, this._script, this._scenarioName);

  static Future<StubServer> bind(String host, int port, ScenarioScript script,
      {String scenarioName = ''}) async {
    final server = await ServerSocket.bind(host, port);
    final stub = StubServer._(server, script, scenarioName);
    server.listen(stub._onConnection,
        onError: (Object e) => stderr.writeln('[stub] server error: $e'));
    return stub;
  }

  Future<void> close() => _server.close();

  /// The bound port (an ephemeral one when bound to 0, as in tests).
  int get port => _server.port;

  void _onConnection(Socket socket) {
    _readRequest(socket).then((req) async {
      if (req == null) return;
      try {
        await _serve(socket, req);
      } catch (e) {
        stderr.writeln('[stub] error serving ${req.path}: $e');
        socket.destroy();
      }
    }).catchError((Object e) {
      // The client hung up or sent garbage; nothing to replay to.
      socket.destroy();
    });
  }

  /// Reads one request (request line + headers + Content-Length body) off the
  /// socket. Returns null if the connection closes before a full request
  /// arrives. One subscription for the whole read — a body that spans several
  /// TCP segments is accumulated in [buf] until complete.
  Future<_RawRequest?> _readRequest(Socket socket) {
    final completer = Completer<_RawRequest?>();
    final buf = <int>[];
    late final StreamSubscription sub;
    var headerEnd = -1;
    var bodyStart = 0;
    var contentLength = 0;
    var method = '';
    var path = '';

    void tryFinish() {
      if (headerEnd < 0) {
        headerEnd = _indexOf(buf, '\r\n\r\n');
        if (headerEnd < 0) return;
        final lines =
            utf8.decode(buf.sublist(0, headerEnd)).split('\r\n');
        final parts = lines.first.split(' ');
        if (parts.length < 2) {
          sub.cancel();
          completer.complete(null);
          return;
        }
        method = parts[0];
        path = parts[1];
        for (final h in lines.skip(1)) {
          final c = h.indexOf(':');
          if (c < 0) continue;
          if (h.substring(0, c).trim().toLowerCase() == 'content-length') {
            contentLength = int.tryParse(h.substring(c + 1).trim()) ?? 0;
          }
        }
        bodyStart = headerEnd + 4;
      }
      if (buf.length - bodyStart >= contentLength) {
        sub.cancel();
        completer.complete(_RawRequest(method, path,
            List<int>.unmodifiable(buf.sublist(bodyStart, bodyStart + contentLength))));
      }
    }

    sub = socket.listen((chunk) {
      buf.addAll(chunk);
      if (!completer.isCompleted) tryFinish();
    },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.complete(null);
        });
    return completer.future;
  }

  Future<void> _serve(Socket socket, _RawRequest req) async {
    if (req.method == 'GET' && req.path == '/healthz') {
      _respond(socket, 200, 'text/plain', [utf8.encode('ok')]);
      return;
    }
    if (req.method == 'POST' && req.path == '/__reset') {
      _requestCount = 0;
      stdout.writeln('[stub] step counter reset');
      _respond(
          socket, 200, 'text/plain', [utf8.encode('reset')]);
      return;
    }
    if (req.method != 'POST') {
      _respond(socket, 404, 'text/plain',
          [utf8.encode('not found')]);
      return;
    }

    final turn = _requestCount++;
    final step = _script.stepFor(turn);
    stdout.writeln('[stub] $_scenarioName '
        'turn=${turn + 1} step=${_script.steps.indexOf(step) + 1} '
        '${req.method} ${req.path} -> ${step.status} '
        '(${req.body.length} bytes in, '
        '${step.actions.whereType<WriteLine>().length} lines out'
        '${step.actions.any((a) => a is Abort) ? ', abort' : ''})');

    socket.add(utf8.encode('HTTP/1.1 ${step.status} ${_reason(step.status)}\r\n'
        'content-type: ${step.status == 200 ? 'text/event-stream' : 'application/json'}\r\n'
        'cache-control: no-cache\r\n'
        'connection: close\r\n'
        '\r\n'));
    await socket.flush();
    for (final action in step.actions) {
      switch (action) {
        case WriteLine(:final line):
          socket.add(utf8.encode('$line\n'));
          await socket.flush();
        case Wait(:final duration):
          await Future<void>.delayed(duration);
        case Abort():
          // destroy() rather than close(): the connection ends without a
          // finish frame or [DONE]. To an HTTP client (no content-length,
          // `connection: close`) this reads as a stream cut off mid-tokens —
          // tina assembles the turn from whatever deltas arrived.
          socket.destroy();
          return;
      }
    }
    await socket.close();
  }

  void _respond(Socket socket, int status, String contentType, List<List<int>> body) {
    socket.add(utf8.encode('HTTP/1.1 $status ${_reason(status)}\r\n'
        'content-type: $contentType\r\n'
        'content-length: ${body.fold<int>(0, (n, c) => n + c.length)}\r\n'
        'connection: close\r\n'
        '\r\n'));
    for (final chunk in body) {
      socket.add(chunk);
    }
    socket.destroy();
  }

  static String _reason(int status) => switch (status) {
        200 => 'OK',
        400 => 'Bad Request',
        401 => 'Unauthorized',
        404 => 'Not Found',
        429 => 'Too Many Requests',
        500 => 'Internal Server Error',
        503 => 'Service Unavailable',
        _ => 'Status',
      };

  static int _indexOf(List<int> haystack, String needle) {
    final n = utf8.encode(needle);
    outer:
    for (var i = 0; i <= haystack.length - n.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (haystack[i + j] != n[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

/// A parsed request as seen by the raw-socket server.
class _RawRequest {
  final String method;
  final String path;
  final List<int> body;
  _RawRequest(this.method, this.path, this.body);
}

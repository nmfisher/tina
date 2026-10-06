import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tina_tools/tina_tools.dart'
    show killProcessTree, startCapturedProcess;
import 'config.dart';

typedef RpcMessage = Map<String, dynamic>;
const maxMcpMessageBytes = 32 * 1024 * 1024;

abstract class McpTransport {
  Stream<RpcMessage> get messages;
  Future<void> send(RpcMessage message);
  Future<void> startNotifications() async {}
  void setProtocolVersion(String version) {}
  Future<void> close();
}

Future<McpTransport> connectMcp(McpServerConfig config, String workspace,
    {Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
  String expand(String value) => McpServerConfig.expand(value, env);
  if (config.url != null) {
    return HttpMcpTransport(Uri.parse(expand(config.url!)), {
      for (final e in config.headers.entries) e.key: expand(e.value),
    });
  }
  final process = await startCapturedProcess(
      expand(config.command!), config.arguments.map(expand).toList(),
      workingDirectory: config.directory(workspace),
      environment: {
        ...env,
        for (final e in config.environment.entries) e.key: expand(e.value)
      },
      includeParentEnvironment: false);
  return StdioMcpTransport(process);
}

final class StdioMcpTransport extends McpTransport {
  StdioMcpTransport(this.process) {
    // stdout is protocol only. Bound buffers before decoding a frame.
    final buffer = <int>[];
    _stdout = process.stdout.listen((bytes) {
      if (_closed) return;
      for (final byte in bytes) {
        if (byte == 10) {
          if (buffer.isNotEmpty) {
            try {
              _messages.add(_decode(utf8.decode(buffer)));
            } catch (_) {
              _fail(const FormatException('MCP server sent invalid JSON-RPC'));
              return;
            }
            buffer.clear();
          }
        } else {
          buffer.add(byte);
          if (buffer.length > maxMcpMessageBytes) {
            _fail(const FormatException('MCP message exceeds 32 MiB'));
            return;
          }
        }
      }
    },
        onError: (Object _) => _fail(StateError('MCP stdout failed')),
        onDone: () => _fail(StateError('MCP server closed stdout')));
    // Drain stderr separately: logging is not a failed tool or protocol data.
    _stderr = process.stderr.listen((_) {}, onError: (Object _) {});
    unawaited(process.exitCode.then((code) {
      _fail(StateError('MCP server exited ($code)'));
    }));
  }
  final Process process;
  final _messages = StreamController<RpcMessage>();
  late final StreamSubscription<List<int>> _stdout, _stderr;
  bool _closed = false;
  Future<void>? _closing;
  Future<void> _writes = Future.value();
  @override
  Stream<RpcMessage> get messages => _messages.stream;
  void _fail(Object error) {
    if (_closed) return;
    _messages.addError(error);
    unawaited(close());
  }

  @override
  Future<void> send(RpcMessage message) {
    final write = _writes.then((_) async {
      if (_closed) throw StateError('MCP transport is closed');
      process.stdin.writeln(jsonEncode(message));
      await process.stdin.flush();
    });
    // Server requests, cancellation and client requests can write concurrently.
    // IOSink cannot add data while a preceding flush owns the sink.
    _writes = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    try {
      // A server that stops reading can leave an outstanding flush parked on
      // a full pipe. Closing must still reach process-tree termination.
      await process.stdin.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await killProcessTree(process.pid);
    await _stdout.cancel();
    await _stderr.cancel();
    unawaited(_messages.close());
  }
}

RpcMessage _decode(String text) {
  final value = jsonDecode(text);
  if (value is! Map || value['jsonrpc'] != '2.0') {
    throw const FormatException('Invalid JSON-RPC envelope');
  }
  return Map<String, dynamic>.from(value);
}

/// Stateful Streamable HTTP (2025-03-26 onward). No redirects or request replay:
/// a lost response must never repeat a tool's side effects.
final class HttpMcpTransport extends McpTransport {
  HttpMcpTransport(this.uri, this.headers);
  final Uri uri;
  final Map<String, String> headers;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final _messages = StreamController<RpcMessage>();
  bool _closed = false;
  Future<void>? _closing;
  String? _session, _version;
  @override
  Stream<RpcMessage> get messages => _messages.stream;
  @override
  void setProtocolVersion(String version) => _version = version;
  Future<HttpClientRequest> _request(String method) async {
    if (_closed) throw StateError('MCP transport is closed');
    final request = await _http.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.headers.set('Accept', 'application/json, text/event-stream');
    if (_session != null) request.headers.set('Mcp-Session-Id', _session!);
    if (_version != null)
      request.headers.set('MCP-Protocol-Version', _version!);
    return request;
  }

  @override
  Future<void> send(RpcMessage message) async {
    final request = await _request('POST');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(message));
    final response = await request.close();
    if (response.statusCode == 202 && !message.containsKey('method') ||
        response.statusCode == 202 && !message.containsKey('id')) {
      await response.drain<void>();
      return;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw StateError('MCP HTTP ${response.statusCode} (no automatic retry)');
    }
    final session = response.headers.value('Mcp-Session-Id');
    if (_session == null && session != null) _session = session;
    unawaited(_consume(response, stopId: message['id']).catchError((Object _) {
      if (!_closed)
        _messages.addError(StateError('MCP HTTP response stream failed'));
    }));
  }

  Future<void> _consume(HttpClientResponse response, {Object? stopId}) async {
    final type = response.headers.contentType?.mimeType;
    if (type == 'application/json') {
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > maxMcpMessageBytes)
          throw const FormatException('MCP result too large');
      }
      if (!_closed) _messages.add(_decode(utf8.decode(bytes)));
      return;
    }
    if (type != 'text/event-stream')
      throw const FormatException('Unsupported MCP HTTP content type');
    final data = <int>[];
    final line = <int>[];
    // Parse bytes ourselves to cap unterminated lines as well as complete events.
    await for (final chunk in response) {
      for (final byte in chunk) {
        if (_closed) return;
        if (byte != 10) {
          line.add(byte);
          if (line.length + data.length > maxMcpMessageBytes)
            throw const FormatException('MCP event too large');
          continue;
        }
        final text = utf8.decode(line).replaceFirst(RegExp(r'\r$'), '');
        line.clear();
        if (text.isEmpty && data.isNotEmpty) {
          final value = utf8.decode(data).trim();
          data.clear();
          if (value.isEmpty) continue;
          final message = _decode(value);
          _messages.add(message);
          if (stopId != null &&
              message['id'] == stopId &&
              (message.containsKey('result') || message.containsKey('error')))
            return;
        } else if (text.startsWith('data:')) {
          data.addAll(
              utf8.encode(text.substring(5).replaceFirst(RegExp(r'^ '), '')));
          data.add(10);
        }
      }
    }
    if (stopId != null && !_closed) {
      throw StateError('MCP response ended without completion');
    }
  }

  @override
  Future<void> startNotifications() async {
    final request = await _request('GET');
    final response = await request.close();
    if (response.statusCode == 405) {
      await response.drain<void>();
      return;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw StateError('MCP notification stream HTTP ${response.statusCode}');
    }
    await _consume(response);
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    if (_session != null) {
      try {
        final request =
            await _http.deleteUrl(uri).timeout(const Duration(seconds: 1));
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        request.headers.set('Mcp-Session-Id', _session!);
        if (_version != null)
          request.headers.set('MCP-Protocol-Version', _version!);
        final response =
            await request.close().timeout(const Duration(seconds: 1));
        await response.drain<void>().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    _http.close(force: true);
    unawaited(_messages.close());
  }
}

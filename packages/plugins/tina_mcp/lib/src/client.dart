import 'dart:async';
import 'dart:convert';
import 'package:tina_core/tina_core.dart';
import 'transport.dart';

const mcpProtocolVersions = [
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
  '2024-11-05'
];

final class McpException implements Exception {
  const McpException(this.message, {this.code});
  final String message;
  final int? code;
  @override
  String toString() => message;
}

/// JSON-RPC correlation, lifecycle and cancellation. No renderer or loop types.
final class McpClient {
  McpClient(this.transport,
      {this.timeout = const Duration(seconds: 60), this.workspaceUri}) {
    _subscription = transport.messages.listen(_receive,
        onError: (Object _) => _disconnect('MCP connection failed'),
        onDone: () => _disconnect('MCP connection closed'));
  }
  final McpTransport transport;
  final Duration? timeout;
  final String? workspaceUri;
  final _pending = <int, Completer<RpcMessage>>{};
  late final StreamSubscription<RpcMessage> _subscription;
  int _sequence = 0;
  bool _closed = false;
  bool get closed => _closed;
  String instructions = '';
  RpcMessage capabilities = {};
  void Function()? onToolsChanged;
  void Function()? onDisconnected;

  Future<void> initialize({Future<void>? whenCancelled}) async {
    final result = await request(
        'initialize',
        {
          'protocolVersion': mcpProtocolVersions.first,
          'capabilities': {
            if (workspaceUri != null) 'roots': {'listChanged': false}
          },
          'clientInfo': {'name': 'tina', 'version': '1.0'},
        },
        whenCancelled: whenCancelled,
        cancellable: false);
    final version = result['protocolVersion'];
    if (!mcpProtocolVersions.contains(version)) {
      throw const McpException(
          'MCP server negotiated an unsupported protocol version');
    }
    if (result['capabilities'] is! Map || result['serverInfo'] is! Map) {
      throw const McpException('Invalid MCP initialize response');
    }
    capabilities = Map<String, dynamic>.from(result['capabilities'] as Map);
    instructions = result['instructions'] as String? ?? '';
    transport.setProtocolVersion(version as String);
    await notify('notifications/initialized');
    unawaited(transport.startNotifications().catchError((Object _) {
      _disconnect('MCP notification stream failed');
    }));
  }

  Future<RpcMessage> request(String method, RpcMessage params,
      {Future<void>? whenCancelled, bool cancellable = true}) async {
    if (_closed) throw const McpException('MCP connection is closed');
    final id = ++_sequence;
    final result = Completer<RpcMessage>();
    _pending[id] = result;
    Timer? timer;
    void cancel(String reason) {
      if (_pending.remove(id) == null) return;
      result.completeError(McpException(reason));
      if (cancellable) {
        unawaited(notify(
                'notifications/cancelled', {'requestId': id, 'reason': reason})
            .catchError((Object _) {}));
      }
    }

    if (timeout != null) {
      timer = Timer(
          timeout!,
          () => cancel(
              'MCP request timed out; its operation may still have completed. Inspect the result before retrying.'));
    }
    if (whenCancelled != null) {
      unawaited(whenCancelled.then((_) => cancel(
          'MCP request cancelled; its operation may still have completed.')));
    }
    // Observe the response before writing: transport errors/fast cancellation
    // cannot leave a rejected completer without an error listener.
    final response = result.future;
    response.ignore();
    unawaited(transport.send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params
    }).catchError((Object _) {
      if (_pending.remove(id) != null) {
        result.completeError(
            const McpException('MCP request could not be sent (not retried)'));
      }
    }));
    try {
      return await response;
    } finally {
      _pending.remove(id);
      timer?.cancel();
    }
  }

  Future<void> notify(String method, [RpcMessage params = const {}]) =>
      transport.send({
        'jsonrpc': '2.0',
        'method': method,
        if (params.isNotEmpty) 'params': params
      });

  void _receive(RpcMessage message) {
    final method = message['method'];
    if (method is String) {
      final id = message['id'];
      if (id != null) {
        RpcMessage answer;
        if (method == 'ping') {
          answer = {'result': <String, dynamic>{}};
        } else if (method == 'roots/list' && workspaceUri != null) {
          answer = {
            'result': {
              'roots': [
                {'uri': workspaceUri, 'name': 'Workspace'}
              ]
            }
          };
        } else {
          // Sampling/elicitation are not advertised. Never silently run a model
          // request or accept arbitrary server-initiated input.
          answer = {
            'error': {'code': -32601, 'message': 'Client method not supported'}
          };
        }
        unawaited(transport
            .send({'jsonrpc': '2.0', 'id': id, ...answer}).catchError(
                (Object _) => _disconnect('MCP response could not be sent')));
      } else if (method == 'notifications/tools/list_changed') {
        onToolsChanged?.call();
      }
      return;
    }
    final id = message['id'];
    if (id is! int) return;
    final pending = _pending.remove(id);
    if (pending == null)
      return; // Includes responses arriving after cancellation.
    if (message['error'] is Map) {
      final error = message['error'] as Map;
      // Server error strings may contain credentials; keep diagnostics local.
      pending.completeError(McpException(
          'MCP server rejected the request (${error['code']})',
          code: error['code'] is int ? error['code'] as int : null));
    } else if (message['result'] is Map) {
      pending.complete(Map<String, dynamic>.from(message['result'] as Map));
    } else {
      pending.completeError(const McpException('Invalid MCP response'));
    }
  }

  Future<List<RpcMessage>> list(String method, String field,
      {Future<void>? whenCancelled}) async {
    final items = <RpcMessage>[];
    final cursors = <String>{};
    String? cursor;
    do {
      final page = await request(method, {if (cursor != null) 'cursor': cursor},
          whenCancelled: whenCancelled);
      if (page[field] is! List)
        throw McpException('Invalid MCP $method result');
      for (final item in page[field] as List) {
        if (item is! Map) throw McpException('Invalid MCP $field item');
        items.add(Map<String, dynamic>.from(item));
      }
      if (items.length > 10000)
        throw const McpException('MCP discovery exceeds 10,000 entries');
      cursor = page['nextCursor'] as String?;
      if (cursor != null && (!cursors.add(cursor) || cursors.length > 1000)) {
        throw const McpException('MCP server repeated a pagination cursor');
      }
    } while (cursor != null);
    return items;
  }

  void _disconnect(String message) {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(McpException(message));
    }
    _pending.clear();
    onDisconnected?.call();
    unawaited(transport.close());
  }

  Future<void> close() async {
    _disconnect('MCP client closed');
    await transport.close();
    await _subscription.cancel();
  }
}

/// Keep ordinary text/JSON readable; screenshots stay images, not base64 text.
ToolResult mcpToolResult(RpcMessage result) {
  final text = <String>[];
  final images = <ImageBlock>[];
  final content = result['content'];
  if (content is! List)
    throw const McpException('MCP tool result needs a content list');
  for (final item in content) {
    if (item is! Map) throw const McpException('Invalid MCP result content');
    switch (item['type']) {
      case 'text':
        if (item['text'] is! String)
          throw const McpException('Invalid MCP text');
        text.add(item['text'] as String);
      case 'image':
        final data = item['data'], mime = item['mimeType'];
        if (data is! String ||
            mime is! String ||
            !{'image/png', 'image/jpeg', 'image/gif', 'image/webp'}
                .contains(mime)) {
          throw const McpException('Unsupported MCP image');
        }
        try {
          base64Decode(data);
        } catch (_) {
          throw const McpException('Invalid MCP image data');
        }
        images.add(ImageBlock(data: data, mimeType: mime));
        text.add('[Image: $mime]');
      case 'resource_link':
        text.add(jsonEncode(item));
      case 'resource':
        final resource = item['resource'];
        if (resource is! Map)
          throw const McpException('Invalid embedded MCP resource');
        text.add(jsonEncode(resource));
      case 'audio':
        // Explicitly signal this limitation instead of treating binary audio
        // as ordinary text or silently dropping it.
        text.add('[MCP audio output is not supported by this client]');
      default:
        throw McpException(
            'Unsupported MCP result content type: ${item['type']}');
    }
  }
  if (result['structuredContent'] != null) {
    final structured = jsonEncode(result['structuredContent']);
    if (!text.contains(structured)) text.add(structured);
  }
  return ToolResult(text.join('\n'),
      images: images,
      isError: result['isError'] == true ||
          content.any((c) => c is Map && c['type'] == 'audio'));
}

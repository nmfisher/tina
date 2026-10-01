import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_mcp/tina_mcp.dart';

void main() {
  late HttpServer server;
  late McpClient client;
  late List<Map<String, dynamic>> requests;
  late List<HttpHeaders> headers;
  late Completer<void> deleted;
  var calls = 0;
  var failCall = false;
  setUp(() async {
    requests = [];
    headers = [];
    calls = 0;
    failCall = false;
    deleted = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      headers.add(request.headers);
      if (request.method == 'GET') {
        request.response.statusCode = 405;
        await request.response.close();
        return;
      }
      if (request.method == 'DELETE') {
        deleted.complete();
        request.response.statusCode = 204;
        await request.response.close();
        return;
      }
      final message = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      requests.add(message);
      final method = message['method'];
      if (method == 'notifications/initialized' ||
          method == 'notifications/cancelled' ||
          method == null) {
        request.response.statusCode = 202;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      Object result;
      if (method == 'initialize') {
        request.response.headers.set('Mcp-Session-Id', 'fixture-session');
        result = {
          'protocolVersion': '2025-11-25',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'http', 'version': '1'}
        };
      } else if (method == 'tools/list') {
        result = {
          'tools': [
            {
              'name': 'scene',
              'inputSchema': {'type': 'object'}
            }
          ]
        };
      } else if (method == 'tools/call') {
        calls++;
        if (failCall) {
          request.response.statusCode = 503;
          await request.response.close();
          return;
        }
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        // Priming, comments, notifications, a server request, then the result.
        request.response.write('id: 1\r\ndata: \r\n\r\n: keepalive\r\n\r\n');
        request.response.write('data: ${jsonEncode({
              'jsonrpc': '2.0',
              'method': 'notifications/tools/list_changed'
            })}\n\n');
        request.response.write('data: ${jsonEncode({
              'jsonrpc': '2.0',
              'id': 'server-ping',
              'method': 'ping'
            })}\n\n');
        await request.response.flush();
        final event = jsonEncode({
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': {
            'content': [
              {'type': 'text', 'text': 'Scene 🧊'}
            ]
          }
        });
        final split = event.indexOf('"result"');
        request.response.write('data: ${event.substring(0, split)}\n');
        request.response.write('data: ${event.substring(split)}\n\n');
        await request.response.close();
        return;
      } else {
        result = {};
      }
      request.response.write(jsonEncode(
          {'jsonrpc': '2.0', 'id': message['id'], 'result': result}));
      await request.response.close();
    });
    final transport = await connectMcp(
        McpServerConfig('remote', {
          'url': 'http://127.0.0.1:${server.port}/mcp',
          'headers': {'Authorization': 'Bearer \${MCP_TEST_TOKEN}'},
        }),
        '.',
        environment: {'MCP_TEST_TOKEN': 'fixture-only'});
    client = McpClient(transport, timeout: const Duration(seconds: 2));
    await client.initialize();
  });
  tearDown(() async {
    await client.close();
    expect(deleted.isCompleted, true);
    await server.close(force: true);
  });

  test('HTTP JSON and SSE results, session headers, server requests, DELETE',
      () async {
    var changes = 0;
    client.onToolsChanged = () => changes++;
    expect((await client.list('tools/list', 'tools')).single['name'], 'scene');
    final result = mcpToolResult(
        await client.request('tools/call', {'name': 'scene', 'arguments': {}}));
    expect(result.content, 'Scene 🧊');
    expect(changes, 1);
    for (var i = 0;
        i < 100 &&
            !requests
                .any((r) => r['id'] == 'server-ping' && r['result'] != null);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requests.any((r) => r['id'] == 'server-ping' && r['result'] != null),
        true);
    expect(headers.first.value('Authorization'), 'Bearer fixture-only');
    expect(headers.first.value('Accept'), contains('text/event-stream'));
    expect(
        headers
            .skip(1)
            .every((h) => h.value('Mcp-Session-Id') == 'fixture-session'),
        true);
    expect(
        headers
            .skip(1)
            .every((h) => h.value('MCP-Protocol-Version') == '2025-11-25'),
        true);
    await client.close();
    await deleted.future.timeout(const Duration(seconds: 1));
  });
  test('failed HTTP tool calls are not automatically retried', () async {
    failCall = true;
    await expectLater(
        client.request('tools/call', {'name': 'scene', 'arguments': {}}),
        throwsA(isA<McpException>()));
    expect(calls, 1);
  });
}

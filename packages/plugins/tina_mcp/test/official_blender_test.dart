import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_mcp/tina_mcp.dart';

/// Optional real-server interoperability test. Install Blender Lab's official
/// server independently; no third-party source or Python SDK is vendored.
void main() {
  final command = Platform.environment['TINA_MCP_BLENDER_COMMAND'];
  test(
      'Blender Lab official server initializes, discovers tools and returns API documentation',
      () async {
    final transport = await connectMcp(
        McpServerConfig('blender', {'command': command!}),
        Directory.current.path);
    final client = McpClient(transport, timeout: const Duration(seconds: 15));
    addTearDown(client.close);
    await client.initialize();
    expect(client.instructions, isNotEmpty);
    final tools = await client.list('tools/list', 'tools');
    expect(
        tools.map((t) => t['name']),
        containsAll([
          'execute_blender_code',
          'get_python_api_docs',
          'get_screenshot_of_area_as_image',
        ]));
    final docs = tools.singleWhere((t) => t['name'] == 'get_python_api_docs');
    expect(docs['inputSchema'], isA<Map>());
    final result = mcpToolResult(await client.request('tools/call', {
      'name': 'get_python_api_docs',
      'arguments': {'identifier': 'bpy.app'},
    }));
    expect(result.isError, false, reason: result.content);
    expect(result.content, contains('bpy.app'));
  },
      skip: command == null
          ? 'Set TINA_MCP_BLENDER_COMMAND to the official blender-mcp executable'
          : false);
}

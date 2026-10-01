library;

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'src/client.dart';
import 'src/config.dart';
import 'src/transport.dart';
export 'src/client.dart' show McpClient, McpException, mcpToolResult;
export 'src/config.dart';
export 'src/transport.dart';

typedef McpApprover = Future<ApprovalDecision> Function({
  required String operation,
  required String target,
  required String reason,
  Map<String, Object?> context,
});
typedef McpConnector = Future<McpTransport> Function(
    McpServerConfig config, String workspace);

final class _Server {
  _Server(this.config, this.client);
  final McpServerConfig config;
  final McpClient client;
  List<Map<String, dynamic>> tools = [];
  bool dirty = true;
}

/// MCP is an ordinary tool-owning plugin. The host supplies an approval
/// capability; this plugin owns protocol, connections and conversation grants.
class McpPlugin extends AgentPlugin {
  McpPlugin(
      {required this.workingDirectory,
      required this.readServers,
      required this.approve,
      this.terminal,
      McpConnector? connect})
      : connect =
            connect ?? ((config, workspace) => connectMcp(config, workspace));
  final String workingDirectory;
  final List<McpServerConfig> Function() readServers;
  final McpApprover approve;
  final Terminal? terminal;
  final McpConnector connect;
  final _servers = <String, _Server>{};
  final _schemas = <ToolSchema>[];
  final _bindings = <String, ({_Server server, String method, String tool})>{};
  final _grants = <String>{};
  final _status = <String, String>{};
  Map<String, String> get serverStatus => Map.unmodifiable(_status);
  AgentLoop? _loop;
  bool _closed = false;
  int _preparation = 0;
  Future<void>? _closing;
  @override
  String get id => 'tina/mcp';
  @override
  List<ToolSchema> get tools => List.unmodifiable(_schemas);
  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    for (final schema in _schemas) {
      final binding = _bindings[schema.name]!;
      loop.registerContextExecutor(
          schema.name, (input, context) => _execute(binding, input, context));
    }
  }

  @override
  Future<void> prepareTurn(TurnContext context) async {
    final preparation = ++_preparation;
    bool abandoned() =>
        _closed || context.cancelled || preparation != _preparation;
    final allConfigs = readServers();
    _status.removeWhere(
        (name, _) => !allConfigs.any((server) => server.name == name));
    for (final server in allConfigs.where((server) => !server.enabled)) {
      _status[server.name] = 'Disabled';
    }
    final configs = allConfigs.where((s) => s.enabled).toList();
    final desired = {for (final config in configs) config.name: config};
    for (final name in _servers.keys.toList()) {
      if (abandoned()) return;
      final server = _servers[name]!;
      if (server.client.closed ||
          desired[name]?.fingerprint != server.config.fingerprint) {
        _servers.remove(name);
        await server.client.close();
        if (abandoned()) return;
        _grants.removeWhere((grant) => grant.startsWith('$name\n'));
      }
    }
    for (final config in configs) {
      if (abandoned()) return;
      McpClient? connecting;
      var server = _servers[config.name];
      try {
        if (server == null) {
          _status[config.name] = 'Connecting';
          final transport = await connect(config, workingDirectory);
          connecting = McpClient(transport,
              timeout: config.timeout,
              workspaceUri: Uri.directory(workingDirectory).toString());
          if (abandoned()) {
            await connecting.close();
            return;
          }
          await connecting.initialize(whenCancelled: context.whenCancelled);
          server = _Server(config, connecting);
          server.client.onToolsChanged = () => server!.dirty = true;
          server.client.onDisconnected = () {
            if (identical(_servers[config.name], server)) {
              _status[config.name] = 'Disconnected';
            }
          };
          if (abandoned()) {
            await connecting.close();
            return;
          }
          _servers[config.name] = server;
        }
        if (server.dirty) {
          // Reset before discovery so a notification during the request is
          // retained for the next turn, rather than lost when it completes.
          server.dirty = false;
          final discovered = server.client.capabilities.containsKey('tools')
              ? await server.client.list('tools/list', 'tools',
                  whenCancelled: context.whenCancelled)
              : [];
          if (abandoned()) {
            if (identical(_servers[config.name], server)) server.dirty = true;
            return;
          }
          server.tools = List<Map<String, dynamic>>.from(discovered);
        }
        if (abandoned()) return;
        _status[config.name] = '${server.tools.length} tools connected';
      } catch (error) {
        if (abandoned()) {
          // A cancelled hook may finish after a fresh turn has connected the
          // same server. Clean up only resources that this attempt still owns.
          if (connecting != null &&
              !identical(_servers[config.name]?.client, connecting)) {
            await connecting.close();
          }
          if (server != null && identical(_servers[config.name], server))
            server.dirty = true;
          return;
        }
        if (server != null && identical(_servers[config.name], server))
          _servers.remove(config.name);
        await (server?.client ?? connecting)?.close();
        _status[config.name] = 'Unavailable';
        // Connection diagnostics never include credentials, env values or URLs.
        terminal?.writeln(
            'MCP ${config.name}: unavailable (${error.runtimeType}). Check its configuration and server.');
      }
    }
    if (abandoned()) return;
    _schemas.clear();
    _bindings.clear();
    for (final server in _servers.values) {
      for (final tool in server.tools) {
        final name = tool['name'], input = tool['inputSchema'];
        if (name is! String || name.isEmpty || input is! Map) {
          throw const McpException('Invalid MCP tool definition');
        }
        _add(
            server,
            name,
            'tools/call',
            tool['description'] as String? ?? 'MCP tool $name',
            Map<String, dynamic>.from(input),
            title: tool['title'] as String?);
      }
      if (server.client.capabilities.containsKey('resources')) {
        _add(server, 'list_resources', 'resources/list',
            'List resources on this MCP server.', {
          'type': 'object',
          'properties': {
            'cursor': {'type': 'string'}
          }
        });
        _add(server, 'list_resource_templates', 'resources/templates/list',
            'List resource URI templates on this MCP server.', {
          'type': 'object',
          'properties': {
            'cursor': {'type': 'string'}
          }
        });
        _add(server, 'read_resource', 'resources/read',
            'Read an MCP resource by URI.', {
          'type': 'object',
          'properties': {
            'uri': {'type': 'string'}
          },
          'required': ['uri']
        });
      }
      if (server.client.capabilities.containsKey('prompts')) {
        _add(server, 'list_prompts', 'prompts/list',
            'List prompts on this MCP server.', {
          'type': 'object',
          'properties': {
            'cursor': {'type': 'string'}
          }
        });
        _add(server, 'get_prompt', 'prompts/get',
            'Retrieve an MCP prompt by name and optional string arguments.', {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'arguments': {
              'type': 'object',
              'additionalProperties': {'type': 'string'}
            }
          },
          'required': ['name']
        });
      }
    }
    // Registration is synchronous and scoped to the owner, just like the
    // initial mount. Removed tools remain undispatchable; unload removes all.
    if (_loop != null) _loop!.mountPlugin(this);
  }

  void _add(_Server server, String tool, String method, String description,
      Map<String, dynamic> input,
      {String? title}) {
    final raw = '${server.config.name}/$method/$tool';
    final hash = sha256.convert(utf8.encode(raw)).toString().substring(0, 12);
    final slug = '${server.config.name}_$tool'
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final name =
        'mcp_${slug.substring(0, slug.length > 46 ? 46 : slug.length)}_$hash';
    if (_bindings.containsKey(name))
      throw const McpException('Duplicate MCP tool name');
    _bindings[name] = (server: server, method: method, tool: tool);
    _schemas.add(ToolSchema(
        name: name,
        description: '[MCP ${server.config.name}] $description',
        inputSchema: input,
        describe: (arguments) => ToolDescription(
              title: '${server.config.name}: ${title ?? tool}',
              fields: {
                for (final e in arguments.entries)
                  e.key: e.value is String
                      ? e.value as String
                      : jsonEncode(e.value)
              },
            )));
  }

  @override
  void onPrompt(TurnContext context) {
    for (final server in _servers.values) {
      if (server.client.instructions.isNotEmpty) {
        context.promptSections.add(
            'Instructions from configured MCP server ${server.config.name}:\n${server.client.instructions}');
      }
    }
    if (_servers.isNotEmpty)
      context.promptSections.add(
          'MCP tools interact with configured external applications. Use their advertised schemas. '
          'A timeout or cancellation does not guarantee that the external operation was undone; inspect state before retrying.');
  }

  Future<ToolResult> _execute(
      ({_Server server, String method, String tool}) binding,
      Map<String, Object?> input,
      ToolExecutionContext context) async {
    final server = binding.server;
    if (_closed || server.client.closed || context.isCancelled())
      return ToolResult.error(
          'MCP server is unavailable or the call was cancelled');
    final params = Map<String, dynamic>.from(input);
    Object? canonical(Object? value) => value is Map
        ? {
            for (final key in value.keys.cast<String>().toList()..sort())
              key: canonical(value[key])
          }
        : value is List
            ? value.map(canonical).toList()
            : value;
    final grant =
        '${server.config.name}\n${server.config.fingerprint}\n${binding.method}\n${binding.tool}\n${jsonEncode(canonical(params))}';
    if (!_grants.contains(grant)) {
      final decision = await approve(
          operation: 'use MCP tool',
          target: '${server.config.name}: ${binding.tool}',
          reason: 'Allow this call on the configured MCP server?',
          context: {
            'workspace': workingDirectory,
            'mcp_server': server.config.name,
            'mcp_method': binding.method,
            'mcp_tool': binding.tool,
            'arguments': params,
            'permission_scope': 'mcp',
            'permission_scope_label': 'this exact MCP call',
            'permission_scope_description':
                'Session approval covers this exact MCP server, tool and arguments for this conversation.',
            'description': ToolDescription(
                title: '${server.config.name}: ${binding.tool}',
                fields: {
                  for (final e in params.entries)
                    e.key: e.value is String
                        ? e.value as String
                        : jsonEncode(e.value)
                }).toJson(),
          });
      if (_closed ||
          context.isCancelled() ||
          decision == ApprovalDecision.deny) {
        return ToolResult.error('MCP call denied or cancelled');
      }
      if (decision == ApprovalDecision.allowAlways) _grants.add(grant);
    }
    try {
      final result = await server.client.request(
          binding.method,
          binding.method == 'tools/call'
              ? {'name': binding.tool, 'arguments': params}
              : params,
          whenCancelled: context.whenCancelled);
      return binding.method == 'tools/call'
          ? mcpToolResult(result)
          : ToolResult(jsonEncode(result));
    } on McpException catch (error) {
      return ToolResult.error(error.message);
    }
  }

  Future<void> shutdown() => _closing ??= _shutdown();
  Future<void> _shutdown() async {
    _closed = true;
    _grants.clear();
    final servers = _servers.values.toList();
    _servers.clear();
    await Future.wait(servers.map((server) => server.client.close()));
  }

  @override
  void closeSession() {
    unawaited(shutdown());
  }
}

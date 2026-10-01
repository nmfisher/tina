import 'dart:convert';
import 'package:tina_console/tina_console.dart';
import 'package:tina_mcp/tina_mcp.dart';

/// UI attachment; the MCP protocol plugin remains usable without a terminal.
final class McpConsolePlugin extends McpPlugin implements ConsoleContribution {
  McpConsolePlugin(
      {required this.store,
      required super.workingDirectory,
      required super.approve,
      super.terminal})
      : super(readServers: store.read);
  final McpConfigStore store;
  void Function()? _release;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _release = context.settings.registerSection(
        id: 'tina/mcp',
        title: 'MCP servers',
        build: () => [
              SettingText(
                  id: 'add_server',
                  label: 'Add local server (name)',
                  read: () => '',
                  change: (text) {
                    final name = text.trim();
                    if (store.read().any((s) => s.name == name))
                      throw StateError('Server already exists');
                    store.save(McpServerConfig(name, {
                      'command': name == 'blender' ? 'blender-mcp' : name,
                      'enabled': false
                    }));
                    context.settings.refresh();
                  }),
              SettingText(
                  id: 'add_http_server',
                  label: 'Add HTTP server (name)',
                  read: () => '',
                  change: (text) {
                    final name = text.trim();
                    if (store.read().any((s) => s.name == name))
                      throw StateError('Server already exists');
                    store.save(McpServerConfig(name, {
                      'url': 'http://localhost:8000/mcp',
                      'enabled': false
                    }));
                    context.settings.refresh();
                  }),
              for (final server in store.read()) ...[
                SettingToggle(
                    id: '${server.name}/enabled',
                    label: server.name,
                    read: () => server.enabled,
                    change: (enabled) {
                      store.save(server.withValue('enabled', enabled));
                      context.settings.refresh();
                    }),
                SettingAction(
                    id: '${server.name}/status',
                    label:
                        '${server.name}: ${serverStatus[server.name] ?? (server.enabled ? 'Connects on next message' : 'Disabled')}',
                    invoke: () => terminal?.writeln(
                        'MCP ${server.name}: ${serverStatus[server.name] ?? 'connects on next message'}; configuration changes apply to the next message.')),
                if (server.command != null) ...[
                  _text(context, server, 'command', 'Command', server.command!),
                  _json(context, server, 'args', 'Arguments (JSON list)',
                      server.arguments),
                  _text(
                      context,
                      server,
                      'cwd',
                      'Directory (relative to workspace)',
                      server.values['cwd'] as String? ?? '.'),
                  _json(
                      context,
                      server,
                      'env',
                      'Environment (JSON; supports \${VARIABLE})',
                      server.environment,
                      secret: true),
                ] else ...[
                  _text(context, server, 'url', 'URL', server.url!),
                  _json(context, server, 'headers',
                      'Headers (JSON; supports \${VARIABLE})', server.headers,
                      secret: true),
                ],
                SettingText(
                    id: '${server.name}/timeout_ms',
                    label:
                        '${server.name} timeout in milliseconds (0 = unlimited)',
                    read: () =>
                        formatInteger(server.timeout?.inMilliseconds ?? 0),
                    change: (text) {
                      final value =
                          int.tryParse(text.replaceAll(',', '').trim());
                      if (value == null || value < 0)
                        throw const FormatException(
                            'Timeout must be a nonnegative integer');
                      store.save(server.withValue('timeout_ms', value));
                      context.settings.refresh();
                    }),
              ],
            ]);
  }

  SettingText _text(ConsoleContext context, McpServerConfig server, String key,
          String label, String value) =>
      SettingText(
          id: '${server.name}/$key',
          label: '${server.name} $label',
          read: () => value,
          change: (text) {
            store.save(server.withValue(key, text));
            context.settings.refresh();
          });
  SettingText _json(ConsoleContext context, McpServerConfig server, String key,
          String label, Object value,
          {bool secret = false}) =>
      SettingText(
          id: '${server.name}/$key',
          label: '${server.name} $label',
          read: () => jsonEncode(value),
          secret: secret,
          change: (text) {
            store.save(server.withValue(key, jsonDecode(text)));
            context.settings.refresh();
          });
  @override
  void repaintConsole() {}
  @override
  void detachConsole() {
    _release?.call();
    _release = null;
  }

  @override
  void closeSession() {
    detachConsole();
    super.closeSession();
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:tina_console/tina_console.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_settings/tina_settings.dart';

/// One attachment's settings bindings over session-owned MCP configuration.
final class McpView implements ConsoleContribution {
  McpView(this.mcp);
  final McpManagement mcp;
  void Function()? _release;
  void Function()? _unsubscribe;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _release = context.settings.registerSection(
      id: 'tina/mcp',
      title: 'MCP servers',
      build: () => [
        if (!mcp.canControl)
          for (final name in mcp.serverNames)
            SettingAction(
              id: '$name/status',
              label: '$name: ${mcp.serverStatus[name] ?? 'Not connected'}',
              invoke: () => context.chat.writeln(
                'MCP $name: ${mcp.serverStatus[name] ?? 'Not connected'}',
              ),
            ),
        if (mcp.canControl) ...[
          SettingText(
            id: 'add_server',
            scopes: const {SettingScope.global},
            label: 'Add local server (name)',
            read: () => '',
            change: mcp.addLocalServer,
          ),
          SettingText(
            id: 'add_http_server',
            scopes: const {SettingScope.global},
            label: 'Add HTTP server (name)',
            read: () => '',
            change: mcp.addHttpServer,
          ),
          for (final server in mcp.servers) ...[
            SettingToggle(
              id: '${server.name}/enabled',
              scopes: const {SettingScope.global},
              label: server.name,
              read: () => server.enabled,
              change: (enabled) {
                mcp.setValue(server.name, 'enabled', enabled);
              },
            ),
            SettingAction(
              id: '${server.name}/status',
              label:
                  '${server.name}: ${mcp.serverStatus[server.name] ?? (server.enabled ? 'Connects on next message' : 'Disabled')}',
              invoke: () => context.chat.writeln(
                'MCP ${server.name}: ${mcp.serverStatus[server.name] ?? 'connects on next message'}; configuration changes apply to the next message.',
              ),
            ),
            if (server.command != null) ...[
              _text(server, 'command', 'Command', server.command!),
              _json(server, 'args', 'Arguments (JSON list)', server.arguments),
              _text(
                server,
                'cwd',
                'Directory (relative to workspace)',
                server.values['cwd'] as String? ?? '.',
              ),
              _json(
                server,
                'env',
                'Environment (JSON; supports \${VARIABLE})',
                server.environment,
                secret: true,
              ),
            ] else ...[
              _text(server, 'url', 'URL', server.url!),
              _json(
                server,
                'headers',
                'Headers (JSON; supports \${VARIABLE})',
                server.headers,
                secret: true,
              ),
            ],
            SettingText(
              id: '${server.name}/timeout_ms',
              scopes: const {SettingScope.global},
              label: '${server.name} timeout in milliseconds (0 = unlimited)',
              read: () => formatInteger(server.timeout?.inMilliseconds ?? 0),
              change: (text) {
                final value = int.tryParse(text.replaceAll(',', '').trim());
                if (value == null || value < 0)
                  throw const FormatException(
                    'Timeout must be a nonnegative integer',
                  );
                mcp.setValue(server.name, 'timeout_ms', value);
              },
            ),
          ],
        ],
      ],
    );
    final subscription = mcp.changes.listen((_) => context.settings.refresh());
    _unsubscribe = context.own(() => unawaited(subscription.cancel()));
  }

  SettingText _text(
    McpServerConfig server,
    String key,
    String label,
    String value,
  ) => SettingText(
    id: '${server.name}/$key',
    scopes: const {SettingScope.global},
    label: '${server.name} $label',
    read: () => value,
    change: (text) {
      mcp.setValue(server.name, key, text);
    },
  );
  SettingText _json(
    McpServerConfig server,
    String key,
    String label,
    Object value, {
    bool secret = false,
  }) => SettingText(
    id: '${server.name}/$key',
    scopes: const {SettingScope.global},
    label: '${server.name} $label',
    read: () => jsonEncode(value),
    secret: secret,
    change: (text) {
      mcp.setValue(server.name, key, jsonDecode(text));
    },
  );
  @override
  void repaintConsole() {}
  @override
  void detachConsole() {
    _unsubscribe?.call();
    _unsubscribe = null;
    _release?.call();
    _release = null;
  }
}

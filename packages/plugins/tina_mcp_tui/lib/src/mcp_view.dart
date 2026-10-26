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
          // One row per server: the row shows the live On/Off state plus the
          // connection status, and Enter opens the details (toggle, status,
          // connection fields, timeout). Controls resolve the stored config
          // by name on every rebuild so a toggle never edits a captured
          // pre-change snapshot.
          for (final server in mcp.servers)
            SettingGroup(
              id: server.name,
              label: server.name,
              value: () {
                final state = server.enabled ? 'On' : 'Off';
                final status = mcp.serverStatus[server.name];
                return status == null ? state : '$state · $status';
              },
              controls: () => _serverControls(context, server.name),
            ),
        ],
      ],
    );
    final subscription = mcp.changes.listen((_) => context.settings.refresh());
    _unsubscribe = context.own(() => unawaited(subscription.cancel()));
  }

  List<SettingControl> _serverControls(ConsoleContext context, String name) {
    final server = mcp.servers.where((s) => s.name == name).firstOrNull;
    if (server == null) {
      return [
        SettingAction(
          id: '$name/gone',
          label: '$name no longer exists',
          invoke: () {},
        ),
      ];
    }
    return [
      SettingToggle(
        id: '$name/enabled',
        scopes: const {SettingScope.global},
        label: 'Enabled',
        read: () => server.enabled,
        change: (enabled) {
          mcp.setValue(name, 'enabled', enabled);
        },
      ),
      SettingAction(
        id: '$name/status',
        label:
            '$name: ${mcp.serverStatus[name] ?? (server.enabled ? 'Connects on next message' : 'Disabled')}',
        invoke: () => context.chat.writeln(
          'MCP $name: ${mcp.serverStatus[name] ?? 'connects on next message'}; configuration changes apply to the next message.',
        ),
      ),
      if (server.command != null) ...[
        _text(name, 'command', 'Command', server.command!),
        _json(name, 'args', 'Arguments (JSON list)', server.arguments),
        _text(
          name,
          'cwd',
          'Directory (relative to workspace)',
          server.values['cwd'] as String? ?? '.',
        ),
        _json(
          name,
          'env',
          'Environment (JSON; supports \${VARIABLE})',
          server.environment,
          secret: true,
        ),
      ] else ...[
        _text(name, 'url', 'URL', server.url!),
        _json(
          name,
          'headers',
          'Headers (JSON; supports \${VARIABLE})',
          server.headers,
          secret: true,
        ),
      ],
      SettingText(
        id: '$name/timeout_ms',
        scopes: const {SettingScope.global},
        label: 'Timeout in milliseconds (0 = unlimited)',
        read: () => formatInteger(server.timeout?.inMilliseconds ?? 0),
        change: (text) {
          final value = int.tryParse(text.replaceAll(',', '').trim());
          if (value == null || value < 0) {
            throw const FormatException(
              'Timeout must be a nonnegative integer',
            );
          }
          mcp.setValue(name, 'timeout_ms', value);
        },
      ),
    ];
  }

  SettingText _text(
    String name,
    String key,
    String label,
    String value,
  ) => SettingText(
    id: '$name/$key',
    scopes: const {SettingScope.global},
    label: label,
    read: () => value,
    change: (text) {
      mcp.setValue(name, key, text);
    },
  );
  SettingText _json(
    String name,
    String key,
    String label,
    Object value, {
    bool secret = false,
  }) => SettingText(
    id: '$name/$key',
    scopes: const {SettingScope.global},
    label: label,
    read: () => jsonEncode(value),
    secret: secret,
    change: (text) {
      mcp.setValue(name, key, jsonDecode(text));
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

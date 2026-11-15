import 'dart:async';
import 'dart:io';
import 'dart:convert';

Future<bool> copyChatText(String text) async {
  final commands = Platform.isMacOS
      ? [
          ['/usr/bin/pbcopy']
        ]
      : [
          ['/usr/bin/wl-copy'],
          ['/usr/bin/xclip', '-selection', 'clipboard']
        ];
  for (final command in commands) {
    Process? process;
    try {
      process = await Process.start(command.first, command.skip(1).toList(),
          includeParentEnvironment: false,
          environment: {
            'PATH': '/usr/bin:/bin',
            for (final key in [
              'HOME',
              'TMPDIR',
              'LANG',
              'LC_CTYPE',
              'DISPLAY',
              'WAYLAND_DISPLAY',
              'XDG_RUNTIME_DIR',
              'XAUTHORITY',
              'DBUS_SESSION_BUS_ADDRESS'
            ])
              if (Platform.environment[key] case final String value) key: value,
          });
      process.stdin.encoding = utf8;
      final out = process.stdout.drain<void>();
      final err = process.stderr.drain<void>();
      process.stdin.write(text);
      await process.stdin.close().timeout(const Duration(seconds: 3));
      final code = await process.exitCode.timeout(const Duration(seconds: 3));
      await Future.wait([out, err]).timeout(const Duration(seconds: 3));
      if (code == 0) return true;
    } catch (_) {
      process?.kill();
    }
  }
  return false;
}

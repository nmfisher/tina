import 'dart:io';

import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_plugin_registry/tina_plugin_registry.dart';

/// The host-side half of `/plugins build`: the command family is the
/// wasm engine's, but the compile runs where the toolchain lives — in
/// this front-end process (the engine component cannot spawn
/// processes). This contribution intercepts `/plugins build
/// <source-dir>` before submission, runs the shared [PluginBuildFlow]
/// (compile with the local Dart SDK, consent by artifact hash, cache
/// install with a LOCAL origin marker), and — when the session has a
/// plugins command family (a plugin attached) — offers
/// `/plugins reload` through the session so the engine's PluginManager
/// picks the new artifact up (counters increment). The same flow is
/// the engine's agent-facing `plugin_build` tool: one implementation,
/// two surfaces.
///
/// No background watcher, no polling: explicit build-then-reload only.
final class PluginBuildContribution
    implements ConsoleContribution, ConsoleCommandHandler {
  PluginBuildContribution(this._connection, {PluginBuildService? service})
      : _service = service;

  final SessionConnection _connection;
  final PluginBuildService? _service;
  ConsoleContext? _console;

  PluginBuildService _resolveService() =>
      _service ??
      PluginBuildService(
        cache: PluginCache(root: Directory(_pluginCacheRoot())),
        compiler: sdkWasmCompiler(),
      );

  static String _pluginCacheRoot() {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home${Platform.pathSeparator}.tina${Platform.pathSeparator}plugins';
  }

  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    if (name != 'plugins') return null;
    final rest = arguments.trim();
    if (rest != 'build' && !rest.startsWith('build ')) return null;
    final console = _console;
    if (console == null) return null;
    return console.interact(() async {
      if (!console.isActive) return;
      final source = rest.startsWith('build ')
          ? rest.substring('build '.length).trim()
          : '';
      if (source.isEmpty) {
        _notice('plugins build needs a source directory '
            '(/plugins build <source-dir>)');
        return;
      }
      final service = _resolveService();
      final directory = Directory(source.startsWith('/') || source.startsWith('.')
          ? source
          : '${Directory.current.path}${Platform.pathSeparator}$source');
      final name = pluginSourceName(directory);
      await PluginBuildFlow(
        buildArtifact: (sourcePath) =>
            service.build(Directory(sourcePath), name),
        consent: LocalPluginConsent(
            file: File('${service.cache.root.path}'
                '${Platform.pathSeparator}local-consent.json')),
        prompt: _consentPrompt,
        notice: _notice,
        reload: () async {
          final reload = _connection.offerCommand('/plugins reload');
          if (reload != null) await reload;
        },
        attached: () => _connection.commands
            .any((command) => command.name == 'plugins'),
      ).run(directory.path);
    });
  }

  /// Yes/No through the shared modal picker machinery (Escape = No).
  Future<bool> _consentPrompt(LocalPluginBuild build) async {
    final console = _console;
    if (console == null) return false;
    final input = console.input.openInputSession();
    try {
      final choice = await runListPickerOverlay(
        screen: console.screen,
        title: 'Install locally-built plugin?',
        items: [
          ListPickerItem('Install ${build.name} ${build.version}',
              detail: 'local build'),
          ListPickerItem('Cancel', detail: 'keep the current artifact'),
        ],
        contextLine:
            'hash ${build.hash.substring(0, 12)}… · skips registry signature '
            'verification (you compiled it); capability grants unchanged',
        readEvent: input.read,
        accent: console.screen.theme.border.focus,
      );
      return choice == 0;
    } finally {
      input.dispose();
    }
  }

  void _notice(String text) {
    _console?.chat.writeln(text);
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
  }

  @override
  void repaintConsole() {}

  @override
  void detachConsole() {
    _console = null;
  }
}

/// The plugin's name: the source directory's pubspec name when
/// present, else the directory's own name.
String pluginSourceName(Directory directory) {
  final pubspec =
      File('${directory.path}${Platform.pathSeparator}pubspec.yaml');
  if (pubspec.existsSync()) {
    for (final line in pubspec.readAsLinesSync()) {
      final match = RegExp(r'^name:\s*(\S+)').firstMatch(line);
      if (match != null) return match.group(1)!;
    }
  }
  return directory.path
      .split(Platform.pathSeparator)
      .where((segment) => segment.isNotEmpty)
      .last;
}

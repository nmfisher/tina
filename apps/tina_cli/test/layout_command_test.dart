import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina/tui.dart'
    show AssemblyOptions, AssemblyWriter, SessionAssembly;
import 'package:tina_console/tina_console.dart' show ScreenLayout;
import 'package:tina_layout/tina_layout.dart';

import '../lib/src/assembly_config.dart';
import '../lib/src/layout_strategies.dart';

/// A captured writer: every line the assembly said.
final class CapturedWriter implements AssemblyWriter {
  final StringBuffer buf = StringBuffer();

  @override
  void writeln([String? line]) => buf.writeln(line ?? '');

  String get text => buf.toString();

  List<String> get lines => const LineSplitter().convert(text.trimRight());
}

/// `/layout` through the real assembly, plus the `layout_strategy`
/// config key. The strategies themselves are golden-tested in
/// tina_console (screen_layout_strategy_test.dart).
void main() {
  tearDown(() => LayoutStrategies.uninstall());

  ({SessionAssembly assembly, CapturedWriter writer}) start() {
    final ws = Directory.systemTemp.createTempSync('tina_layout_ws_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final writer = CapturedWriter();
    final assembly = SessionAssembly.start(
      writer: writer,
      providerFactory: (_) => ScriptedProvider(const []),
      options: AssemblyOptions(
          configPath: '/nonexistent/tina/config',
          workingDirectory: ws.path,
          interactive: false),
    );
    addTearDown(assembly.close);
    return (assembly: assembly, writer: writer);
  }

  test('the shipped presets are registered by name', () {
    expect(
        layoutStrategyFactories.keys,
        containsAll(['default', 'focus', 'two-column']));
    expect(layoutStrategyFactories['focus']!().id, 'focus');
    expect(layoutStrategyFactories['two-column']!().id, 'two-column');
  });

  test('registerLayoutStrategy adds a workspace-declared strategy', () {
    registerLayoutStrategy('acme/wide', () => const FocusScreenTestShim());
    addTearDown(() => layoutStrategyFactories.remove('acme/wide'));
    expect(layoutStrategyFactories['acme/wide']!().id, 'acme/wide');
  });

  test('registerLayoutStrategy rejects malformed names', () {
    expect(() => registerLayoutStrategy('Nope', () => throw StateError('x')),
        throwsArgumentError);
  });

  test('/layout reports the active strategy', () async {
    final env = start();
    await env.assembly.handleCommand('/layout');
    expect(env.writer.lines.last, startsWith('layout strategy: default'));
    expect(env.writer.lines.last, contains('focus'));
  });

  test('/layout focus swaps the live arrangement; /layout default restores',
      () async {
    final env = start();
    await env.assembly.handleCommand('/layout focus');
    expect(LayoutStrategies.active.id, 'focus');
    expect(env.writer.lines.last, startsWith('layout strategy: focus'));
    final swapped = ScreenLayout.fromSize(120, 30, split: false);
    expect(swapped.isSplit, isTrue);
    expect(swapped.chatRightCol, 59);

    await env.assembly.handleCommand('/layout default');
    expect(LayoutStrategies.active.id, 'default');
    final restored = ScreenLayout.fromSize(120, 30, split: false);
    expect(restored.isSplit, isFalse);
  });

  test('/layout with an unknown name refuses and keeps the arrangement',
      () async {
    final env = start();
    await env.assembly.handleCommand('/layout focus');
    await env.assembly.handleCommand('/layoutSideways');
    expect(env.writer.lines.last, startsWith('unknown command: /layoutSideways'));
    expect(LayoutStrategies.active.id, 'focus');
    await env.assembly.handleCommand('/layout sideways');
    expect(env.writer.lines.last, startsWith('unknown layout strategy'));
    expect(LayoutStrategies.active.id, 'focus');
  });

  test('layout_strategy in config selects the strategy at boot', () async {
    final ws = Directory.systemTemp.createTempSync('tina_layout_cfg_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final config = File('${ws.path}/config')..writeAsStringSync('''
[default]
model = "main"
layout_strategy = "two-column"
''');
    final writer = CapturedWriter();
    final assembly = SessionAssembly.start(
      writer: writer,
      providerFactory: (_) => ScriptedProvider(const []),
      options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: ws.path,
          interactive: false),
    );
    addTearDown(assembly.close);
    expect(LayoutStrategies.active.id, 'two-column');
    final layout = ScreenLayout.fromSize(120, 30, split: false);
    expect(layout.infoLeftCol, 0); // mirrored
    expect(writer.text, isNot(contains('unknown layout strategy')));
  });

  test('an unknown layout_strategy in config falls back with a notice',
      () async {
    final ws = Directory.systemTemp.createTempSync('tina_layout_bad_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final config = File('${ws.path}/config')..writeAsStringSync('''
[default]
model = "main"
layout_strategy = "nope"
''');
    final writer = CapturedWriter();
    final assembly = SessionAssembly.start(
      writer: writer,
      providerFactory: (_) => ScriptedProvider(const []),
      options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: ws.path,
          interactive: false),
    );
    addTearDown(assembly.close);
    expect(LayoutStrategies.active.id, 'default');
    expect(writer.text, contains('unknown layout strategy "nope"'));
  });

  test('a malformed layout_strategy value is a config problem', () {
    expect(
        () => parseTinaConfig({
              'default': {'model': 'main'},
              'layout_strategy': 'Not A Name',
            }),
        throwsFormatException);
  });

  test('parseTinaConfig accepts the preset names and defaults', () {
    final result = parseTinaConfig({
      'default': {'model': 'main'},
      'layout_strategy': 'focus',
    });
    expect(result.config.layoutStrategy, 'focus');
    final bare = parseTinaConfig({
      'default': {'model': 'main'},
    });
    expect(bare.config.layoutStrategy, 'default');
  });
}

/// A workspace-declared strategy stand-in: solve-only, no screen policy
/// (the wasm `tina:layout@1.0.0` shape).
final class FocusScreenTestShim implements LayoutStrategy {
  const FocusScreenTestShim();

  @override
  String get id => 'acme/wide';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'acme/wide', version: '1.0.0', description: 'workspace strategy');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    throw UnimplementedError();
  }
}

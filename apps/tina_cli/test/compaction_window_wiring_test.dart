// The window-derived compaction wiring (commit 34), at the assembly:
// the catalog's auto-compact plugin resolves the ACTIVE model's context
// window live through the assembly's descriptor lookup, a /model switch
// moves the trigger without a restart, and the threshold setting
// overrides it (absolute; a written 0 disables). Cross-leg: the same
// wiring builds and fires with the wasm-shaped tools payload (commit
// 28's fixture) — the window seam is capability-typed context access,
// never a plugin-payload cast, so both legs share it.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/portable_tools.dart' show ToolsPluginSurface;
import 'package:tina_tools/testing.dart';

import 'package:tina/src/tools_factory.dart' show injectedToolsPluginFactory;

/// A provider that answers every turn with a fixed-size reply, so the
/// transcript grows by a known token estimate per exchange. Records
/// requests so the summary request is countable.
final class _FixedSizeProvider implements LlmProvider {
  _FixedSizeProvider(this.model, this.replyChars);
  @override
  final String model;
  final int replyChars;
  final requests = <List<Message>>[];
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(List.of(messages));
    yield MessageComplete(
        content: [TextBlock('x' * replyChars)], stopReason: 'end_turn');
  }

  @override
  void close() {}
}

void main() {
  late Directory root;
  late File config;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-compact-window-');
    // glm-5.3 carries a 1M window in the builtin descriptors; glm-4.6
    // carries 131072. The scripted provider factory answers any model.
    config = File('${root.path}/config')
      ..writeAsStringSync('[default]\n'
          'provider = "glm"\n'
          'model = "glm-5.3"\n'
          '[plugins]\n'
          'enabled = ["tina/auto-compact"]\n');
  });

  tearDown(() {
    injectedToolsPluginFactory = null;
    root.deleteSync(recursive: true);
  });

  SessionAssembly open({List<String>? plugins, String? model}) =>
      SessionAssembly.start(
        providerFactory: (m) => _FixedSizeProvider(m, 400000), // ~100K/turn
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: root.path,
          plugins: plugins ?? const ['tina/auto-compact'],
          model: model,
        ),
      );

  test('the catalog registers the threshold setting', () {
    final app = open();
    addTearDown(app.close);
    expect(app.settings.catalog[compactionThresholdSetting.id],
        same(compactionThresholdSetting));
    // No written value: window-derived (source null, not an override).
    final read = app.settings.read(compactionThresholdSetting);
    expect(read.source, isNull);
  });

  test('a 1M-window model does not compact at the old 100K default',
      () async {
    final app = open();
    addTearDown(app.close);
    // Two ~100K exchanges: 200K total — past the old fixed default,
    // far under 80% of the 1M window.
    await app.host.send('one');
    await app.host.send('two');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
  });

  test('a /model switch to a small window compacts live', () async {
    final app = open();
    addTearDown(app.close);
    await app.host.send('one');
    await app.host.send('two');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    // The switch: glm-4.6's 131072 window puts the trigger at ~104858,
    // under the ~200K already in history. The next turn end compacts.
    app.host.switchModel('glm/glm-4.6');
    await app.host.send('three');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('the setting override is absolute and honored live', () async {
    final app = open();
    addTearDown(app.close);
    await app.host.send('one'); // ~100K: under the 1M-window trigger
    await app.host.send('two'); // ~200K: still under it
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    app.settings.set(compactionThresholdSetting, 50000, SettingScope.session);
    await app.host.send('three'); // ~300K: over the written 50K
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('a written 0 disables automatic compaction; /compact still works',
      () async {
    final app = open(model: 'glm/glm-4.6');
    addTearDown(app.close);
    app.settings.set(compactionThresholdSetting, 0, SettingScope.session);
    await app.host.send('one'); // ~100K: over the small window's trigger
    await app.host.send('two'); // ~200K
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty,
        reason: 'a written 0 disables the automatic trigger');
    await app.commands['compact']!.handler('');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1),
        reason: '/compact bypasses the automatic trigger');
  });

  test('the config file seeds the override (plugin_config table)', () async {
    config.writeAsStringSync('[default]\n'
        'provider = "glm"\n'
        'model = "glm-5.3"\n'
        '[plugins]\n'
        'enabled = ["tina/auto-compact"]\n'
        '[plugin_config."tina/auto-compact"]\n'
        'threshold_tokens = 50000\n');
    final app = open();
    addTearDown(app.close);
    final read = app.settings.read(compactionThresholdSetting);
    expect(read.value, 50000);
    expect(read.source, SettingScope.global);
    await app.host.send('one'); // ~100K: over the seeded 50K, but only
    await app.host.send('two'); // two messages — minMessagesToCompact
    // holds until the second exchange exists.
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('an unknown model falls back to the safe default, still enabled',
      () async {
    // A model no descriptor knows: the window is unresolvable, the
    // fallback 100K trigger applies — compaction is never silently off.
    final app = open(model: 'glm/no-such-model');
    addTearDown(app.close);
    await app.host.send('one'); // ~100K: at the fallback trigger, but
    await app.host.send('two'); // minMessagesToCompact needs a second
    // exchange — the fallback fires once history exists.
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('cross-leg: the wasm-shaped payload boots and compacts by window',
      () async {
    // The wasm leg's tools shape (commit 28's fixture): the window seam
    // rides the session context, not the tools payload, so the same
    // wiring fires with the portable surface set.
    final wasmShaped = WasmShapedToolsPlugin();
    injectedToolsPluginFactory = (_) => wasmShaped;
    final app = SessionAssembly.start(
      providerFactory: (m) => _FixedSizeProvider(m, 400000),
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: root.path,
        plugins: const [
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/tools',
          'tina/session-controls',
          'tina/auto-compact',
        ],
      ),
    );
    addTearDown(app.close);
    expect(app.tools, same(wasmShaped));
    expect(app.capability<ToolsPluginSurface>(), same(wasmShaped));
    // 1M window: 200K stays. Switch to the small window: compacts.
    await app.host.send('one');
    await app.host.send('two');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    app.host.switchModel('glm/glm-4.6');
    await app.host.send('three');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
    // The setting path works on this leg too.
    app.settings.set(compactionThresholdSetting, 0, SettingScope.session);
    await app.host.send('four');
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1),
        reason: 'a written 0 disables further automatic compaction');
  });

  test('every catalog setting reads cleanly with the new one registered',
      () async {
    // The settings-open shape (commit 28's live failure site was a cast
    // on this path): the whole catalog constructs and reads over the
    // wasm-shaped payload, now carrying the compaction threshold too.
    final wasmShaped = WasmShapedToolsPlugin();
    injectedToolsPluginFactory = (_) => wasmShaped;
    final app = SessionAssembly.start(
      providerFactory: (m) => _FixedSizeProvider(m, 400),
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: root.path,
        plugins: const [
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/tools',
          'tina/session-controls',
          'tina/auto-compact',
        ],
      ),
    );
    addTearDown(app.close);
    expect(app.settings.catalog.contains(compactionThresholdSetting.id),
        isTrue);
    for (final definition in app.settings.catalog.definitions) {
      expect(app.settings.read(definition).value, isNotNull,
          reason: definition.id);
    }
  });
}

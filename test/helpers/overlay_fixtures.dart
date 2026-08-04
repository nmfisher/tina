import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

import 'fake_stdio.dart';

/// Standard timeout for overlay tests that drive canned input events.
const overlayTimeout = Duration(seconds: 5);

/// A [Screen] rendered over a [FakeStdio] so overlays can paint without a tty.
Screen fakeScreen({int columns = 80, int lines = 24}) {
  final io = FakeStdio()..hasTerminalValue = false;
  final layout = ScreenLayout.fromSize(columns, lines, hasMenuBar: false);
  return Screen(io: io, layout: layout);
}

/// Builds a simple [ProviderDescriptor] for overlay tests.
///
/// [optional] makes the single auth source optional (rather than required).
/// [authRequired] controls whether the descriptor has any auth sources at all;
/// when false, [optional] is ignored.
ProviderDescriptor fakeProviderDescriptor(
  String id, {
  List<String> models = const [],
  bool optional = false,
  bool authRequired = true,
}) {
  final authSources = authRequired
      ? [
          AuthSource(
            '${id.toUpperCase()}_KEY',
            optional ? AuthScheme.none : AuthScheme.bearerToken,
          ),
        ]
      : <AuthSource>[];
  return ProviderDescriptor(
    id: id,
    name: id,
    authSources: authSources,
    defaultBaseUrl: '',
    builder: (_) => throw UnimplementedError(),
    models: {
      for (final m in models)
        m: ModelInfo(id: m, name: m, contextWindow: 1, maxOutput: 1),
    },
  );
}

/// Registry used by the setup/settings/prompts overlays: alpha, beta, local.
ProviderRegistry setupRegistry() => ProviderRegistry(env: {})
  ..register(fakeProviderDescriptor('alpha', models: ['a1', 'a2']))
  ..register(fakeProviderDescriptor('beta', models: ['b1']))
  ..register(fakeProviderDescriptor('local', models: ['m1'], optional: true));

/// Registry used by the spawn overlay: alpha, beta, gamma.
ProviderRegistry spawnRegistry() => ProviderRegistry(env: {})
  ..register(fakeProviderDescriptor('alpha',
      models: ['a1', 'a2'], authRequired: false))
  ..register(
      fakeProviderDescriptor('beta', models: ['b1'], authRequired: false))
  ..register(fakeProviderDescriptor('gamma',
      models: ['g1', 'g2', 'g3'], authRequired: false));

/// Canned event pump. Tests populate [events], then [readEvent] yields them
/// in order.
class CannedEvents {
  List<InputEvent> events = [];
  int _index = 0;

  Future<InputEvent> readEvent() async => events[_index++];

  void clear() {
    events = [];
    _index = 0;
  }
}

/// Temporary directory lifecycle helper for overlay tests that write config.
class TempTinaDir {
  late Directory dir;

  void setUp([String prefix = 'tina_overlay_']) {
    dir = Directory.systemTemp.createTempSync(prefix);
  }

  void tearDown() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

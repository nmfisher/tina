import 'package:test/test.dart';
import 'package:tina_settings/tina_settings.dart';

void main() {
  late SettingDefinition<int> limit;
  late MemorySettingsBackend backend;
  late ScopedSettings settings;
  setUp(() {
    limit = SettingDefinition<int>(
        id: 'acme/worker/limit',
        label: 'Limit',
        description: 'Work limit',
        defaultValue: 10,
        kind: SettingKind.integer,
        minimum: 0);
    final catalog = SettingCatalog()..register(limit);
    backend = MemorySettingsBackend();
    settings = ScopedSettings(catalog: catalog, backend: backend);
  });
  tearDown(() => settings.close());
  test('malformed IDs are rejected consistently', () {
    for (final id in ['limit', 'acme/limit', 'acme/plugin//limit']) {
      expect(
          () => SettingDefinition<int>(
              id: id,
              label: 'Limit',
              description: 'Limit',
              defaultValue: 0,
              kind: SettingKind.integer),
          throwsArgumentError);
    }
  });
  test('precedence, scope views and explicit equal-value overrides', () {
    settings.set(limit, 20, SettingScope.global);
    settings.set(limit, 30, SettingScope.workspace);
    settings.set(limit, 30, SettingScope.session);
    expect(settings.read(limit).source, SettingScope.session);
    expect(settings.read(limit, scope: SettingScope.global).value, 20);
    settings.removeOverride(limit, SettingScope.session);
    expect(settings.read(limit).source, SettingScope.workspace);
    settings.removeOverride(limit, SettingScope.workspace);
    expect(settings.read(limit).value, 20);
    settings.removeOverride(limit, SettingScope.global);
    expect(settings.read(limit).value, 10);
    expect(settings.read(limit).source, isNull);
  });
  test('masked changes remain available without changing effective value', () {
    settings.set(limit, 5, SettingScope.session);
    var applies = 0, refreshes = 0;
    settings.watch(limit, (_) => applies++);
    settings.listen(() => refreshes++);
    settings.set(limit, 25, SettingScope.global);
    expect(applies, 0);
    expect(refreshes, 1);
    settings.removeOverride(limit, SettingScope.session);
    expect(applies, 1);
    expect(settings.read(limit).value, 25);
  });
  test('unsupported scopes and invalid values never reach storage', () {
    final global = SettingDefinition<String>(
        id: 'acme/worker/global',
        label: 'Global',
        description: 'Shared preference',
        defaultValue: '',
        kind: SettingKind.text,
        scopes: {SettingScope.global});
    settings.catalog.register(global);
    expect(() => settings.set(global, 'x', SettingScope.session),
        throwsArgumentError);
    expect(() => settings.set(limit, -1, SettingScope.global),
        throwsFormatException);
    expect(backend.layers, isEmpty);
  });
  test(
      'unknown session values survive edits and watch cleanup is deterministic',
      () {
    backend.write(SettingScope.session, {
      'future/plugin/value': {
        'nested': [1, 2]
      }
    });
    settings.reload();
    var applies = 0;
    final stop = settings.watch(limit, (_) => applies++);
    settings.set(limit, 4, SettingScope.session);
    stop();
    stop();
    settings.set(limit, 5, SettingScope.session);
    expect(applies, 1);
    expect(settings.layer(SettingScope.session)['future/plugin/value'], {
      'nested': [1, 2]
    });
  });
  test('one form validates every field before any write', () {
    expect(() => settings.update(SettingScope.global, {limit.id: -1}),
        throwsFormatException);
    expect(backend.layers, isEmpty);
  });
  test('plugin apply failure is reported separately from saved configuration',
      () {
    settings.watch(limit, (_) => throw StateError('application failed'));
    settings.set(limit, 4, SettingScope.session);
    expect(settings.read(limit).value, 4);
    expect(settings.applicationErrors[limit.id], contains('saved'));
  });
}

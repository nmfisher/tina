import 'dart:convert';
import 'package:test/test.dart';
import 'package:tina_settings/tina_settings.dart';

void main() {
  late SettingCatalog catalog;
  late MemorySettingsBackend backend;
  late ScopedSettings owner;
  late SettingsClient first, second;
  final limit = SettingDefinition<int>(
      id: 'acme/limits/count',
      label: 'Count',
      description: 'Maximum count',
      defaultValue: 2,
      kind: SettingKind.integer,
      minimum: 1);
  final secret = SettingDefinition<String>(
      id: 'acme/auth/token',
      label: 'Token',
      description: 'An authentication token',
      defaultValue: '',
      kind: SettingKind.text,
      secret: true);
  final object = SettingDefinition<Map<String, dynamic>>(
      id: 'acme/options/object',
      label: 'Options',
      description: 'Nested options',
      defaultValue: {
        'items': [1]
      },
      kind: SettingKind.object);
  setUp(() {
    catalog = SettingCatalog()
      ..register(limit)
      ..register(secret)
      ..register(object);
    backend = MemorySettingsBackend();
    owner = ScopedSettings(catalog: catalog, backend: backend);
    first = SettingsClient(owner);
    second = SettingsClient(owner);
  });
  tearDown(() {
    first.close();
    second.close();
    owner.close();
  });

  test('snapshots are immutable data and redact all secret layers', () {
    owner.set(secret, 'global-secret', SettingScope.global);
    owner.set(secret, 'session-secret', SettingScope.session);
    final snapshot = first.snapshot();
    final token = snapshot.catalog[secret.id];
    expect(
        jsonEncode([
          token.defaultValue,
          snapshot.read(token).value,
          for (final scope in SettingScope.values)
            snapshot.override(token, scope),
        ]),
        isNot(contains('-secret')));
    expect(snapshot.read(token).source, SettingScope.session);
    final nested = snapshot.read(snapshot.catalog[object.id]).value as Map;
    expect(() => (nested['items'] as List).add(2), throwsUnsupportedError);
    expect(() => snapshot.applicationErrors.clear(), throwsUnsupportedError);
    owner.set(limit, 4, SettingScope.session);
    expect(snapshot.read(snapshot.catalog[limit.id]).value, 2);
  });

  test('a second attachment cannot overwrite a change made during its edit',
      () {
    final before = second.snapshot();
    first.update(SettingScope.session,
        expectedRevision: first.snapshot().revision, values: {limit.id: 5});
    expect(
        () => second.update(SettingScope.session,
            expectedRevision: before.revision, values: {limit.id: 6}),
        throwsA(isA<SettingsConflict>()));
    expect(owner.read(limit).value, 5);
    final refreshed = second.snapshot();
    second.update(SettingScope.session,
        expectedRevision: refreshed.revision, values: {limit.id: 6});
    expect(owner.read(limit).value, 6);
  });

  test('external backend changes are checked before a mutation', () {
    final before = first.snapshot();
    backend.write(SettingScope.global, {limit.id: 9});
    expect(
        () => first.update(SettingScope.global,
            expectedRevision: before.revision, values: {limit.id: 10}),
        throwsA(isA<SettingsConflict>()));
    expect(backend.read(SettingScope.global)[limit.id], 9);
  });

  test('validation and inheritance remain with the settings owner', () {
    var snapshot = first.snapshot();
    expect(
        () => first.update(SettingScope.session,
            expectedRevision: snapshot.revision, values: {limit.id: 0}),
        throwsFormatException);
    expect(backend.layers, isEmpty);
    first.update(SettingScope.global,
        expectedRevision: snapshot.revision, values: {limit.id: 7});
    snapshot = first.snapshot();
    first.update(SettingScope.session,
        expectedRevision: snapshot.revision, values: {limit.id: 3});
    snapshot = first.snapshot();
    first.update(SettingScope.session,
        expectedRevision: snapshot.revision, remove: {limit.id});
    final result = first.snapshot().read(first.snapshot().catalog[limit.id]);
    expect(result.value, 7);
    expect(result.source, SettingScope.global);
  });

  test('closing one client releases its listeners without closing the owner',
      () {
    var a = 0, b = 0;
    first.listen(() => a++);
    second.listen(() => b++);
    first.close();
    owner.set(limit, 8, SettingScope.session);
    expect(a, 0);
    expect(b, 1);
    expect(first.snapshot, throwsStateError);
    expect(
        second.snapshot().read(second.snapshot().catalog[limit.id]).value, 8);
  });

  test('a failed observer cannot abort a save or silence another client', () {
    var changes = 0;
    first.listen(() => throw StateError('broken editor'));
    second.listen(() => changes++);
    owner.set(limit, 10, SettingScope.session);
    expect(changes, 1);
    expect(owner.read(limit).value, 10);
  });

  test('accepted values cannot be mutated through the submitted request', () {
    final values = <String, dynamic>{
      'items': [2]
    };
    first.update(SettingScope.session,
        expectedRevision: first.snapshot().revision,
        values: {object.id: values});
    (values['items'] as List).add(99);
    expect(owner.read(object).value, {
      'items': [2]
    });
  });
}

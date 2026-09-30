import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

void main() {
  test('state payload is an immutable deep snapshot', () {
    final list = <Object?>[1];
    final value = {'nested': list};
    final e = PluginStateEntry.snapshot(
        pluginId: 'test/state',
        stateKey: 'key',
        schemaVersion: 99,
        value: value);
    list.add(2);
    expect(e.value!['nested'], [1]);
    expect(() => (e.value!['nested'] as List).add(3), throwsUnsupportedError);
    expect(() => e.value!['x'] = true, throwsUnsupportedError);
  });
  test('envelope rejects bad identities, keys, versions and non-JSON values',
      () {
    for (final change in [
      {'plugin_id': 'unnamespaced'},
      {'state_key': ''},
      {'schema_version': -1},
      {'schema_version': 1.5},
      {
        'value': {'x': double.infinity}
      },
      {
        'value': {'x': Object()}
      },
    ]) {
      expect(
          () => SessionEntry.fromJson({
                'type': 'plugin_state',
                'plugin_id': 'test/state',
                'state_key': 'key',
                'schema_version': 1,
                'value': {},
                ...change
              }),
          throwsA(anything));
    }
  });
}

// The one model-catalog rule every surface shares (the settings editors'
// pickers and the connection controls' list): entry order, disabled refs
// excluded, extra providers included, the current ref kept pickable.
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina_settings/tina_settings.dart';

void main() {
  const entries = [
    ModelCatalogEntry(id: 'acme', name: 'Acme', models: {
      'one': 'First model',
      'two': 'Second model',
    }),
    ModelCatalogEntry(id: 'other', name: 'Other', models: {'x': 'X'}),
  ];

  test('refs in entry order with display names', () {
    final choices =
        modelCatalogChoices(entries: entries)!;
    expect(choices.refs, ['acme/one', 'acme/two', 'other/x']);
    expect(choices.providerNames, {'acme': 'Acme', 'other': 'Other'});
    expect(choices.modelNames,
        {'acme/one': 'First model', 'acme/two': 'Second model', 'other/x': 'X'});
  });

  test('disabled models drop out; a display name override wins', () {
    final choices = modelCatalogChoices(
        entries: entries,
        disabled: {
          'acme': {'two'}
        },
        providerNames: {'acme': 'Acme override'})!;
    expect(choices.refs, ['acme/one', 'other/x']);
    expect(choices.providerNames['acme'], 'Acme override');
  });

  test('extra providers appear even without an entry; current stays pickable',
      () {
    final choices = modelCatalogChoices(
        entries: entries, extra: ['ghost'], current: 'ghost/private')!;
    expect(choices.refs, contains('ghost/private'));
    expect(choices.providerNames['ghost'], 'ghost',
        reason: 'an unknown provider falls back to its id');
  });

  test('a disabled current model is not resurrected; empty offers null', () {
    expect(
        modelCatalogChoices(
            entries: const [
              ModelCatalogEntry(id: 'solo', name: 'Solo', models: {'m': 'M'})
            ],
            disabled: {
              'solo': {'m'}
            },
            current: 'solo/m'),
        isNull,
        reason: 'the only ref is disabled, and a disabled current stays out');
    expect(modelCatalogChoices(entries: const []), isNull);
  });
}

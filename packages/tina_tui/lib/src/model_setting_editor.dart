import 'package:tina_console/tina_console.dart';
import 'package:tina_settings/tina_settings.dart';
import 'setting_editors.dart';
import 'settings_management.dart';

/// Everything the searchable model picker offers: `provider/model` refs in
/// registry order plus the display names for providers and models.
typedef ModelChoices = ({
  List<String> refs,
  Map<String, String> providerNames,
  Map<String, String> modelNames
});

/// Edits text settings that hold `provider/model` references through the
/// shared searchable model picker: one ref per configured provider's model,
/// `disabled_models` excluded, the current value offered even when the
/// catalog does not list it. Without a provider catalog the panel's text
/// editor stays available. The application layer wires settings to this
/// editor by definition identity; settings definitions stay domain-free.
final class ModelSettingEditor implements ScopedSettingEditor {
  ModelSettingEditor(Iterable<SettingDefinition<String>> settings)
      : _ids = Set.unmodifiable(settings.map((setting) => setting.id));
  final Set<String> _ids;

  @override
  bool handles(SettingInfo definition) =>
      definition.kind == SettingKind.text && _ids.contains(definition.id);

  @override
  Future<String?> edit(ScopedSettingEdit edit) async {
    final draft = edit.openDraft();
    final ModelChoices? choices;
    try {
      choices = modelChoices(draft, edit.providers, edit.value);
    } finally {
      edit.closeDraft(draft);
    }
    if (choices == null)
      return edit.editText(edit.definition.label, edit.value);
    return searchModelPicker(
        screen: edit.screen,
        title: edit.title(edit.definition.label),
        choices: choices,
        bounds: edit.bounds,
        contextLine: edit.contextLine,
        readEvent: edit.readEvent,
        hideOverlay: edit.hideOverlay,
        setRepaint: edit.setRepaint);
  }
}

/// Everything the model picker can offer: one `provider/model` ref per
/// configured provider's models (`providerModels(descriptor, fields)`),
/// honoring `disabled_models`, plus [current] (`provider/model`, empty when
/// unset) when it is not already listed — the current value stays pickable
/// even when the catalog does not carry it. Null when no provider supplies
/// any model, so callers can fall back to another editor. The list itself
/// is the shared `modelCatalogChoices` rule; only the draft-merging of
/// provider tables is editor-local.
ModelChoices? modelChoices(
    ProviderDraft document, List<ProviderOption> descriptors, String current) {
  final providers = document.table('providers');
  // An empty providers table means the descriptor catalog as-is; a
  // configured table decides which providers exist.
  final configured = providers.isEmpty
      ? descriptors.map((d) => d.id).toList()
      : providers.keys.cast<String>().toList();
  ModelCatalogEntry entry(String id) {
    ProviderOption? descriptor;
    for (final candidate in descriptors) {
      if (candidate.id == id) descriptor = candidate;
    }
    final values = (providers[id] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return ModelCatalogEntry(
        id: id,
        name: descriptor?.name ?? id,
        models: providerModels(descriptor, values));
  }

  return modelCatalogChoices(
      entries: [for (final id in configured) entry(id)],
      providerNames: {
        for (final id in configured)
          if (((providers[id] as Map?)?['name'] as String?) case final name?)
            id: name,
      },
      disabled: {
        for (final id in configured)
          id: (((providers[id] as Map?)?['disabled_models'] as List?)
                      ?.cast<String>() ??
                  const [])
              .toSet(),
      },
      current: current);
}

/// The one shared [ModelSearchPicker] construction, used by the
/// default-model editor and [ModelSettingEditor] alike. Returns the chosen
/// `provider/model` ref, or null when cancelled.
Future<String?> searchModelPicker(
    {required Screen screen,
    required String title,
    required ModelChoices choices,
    required Rect Function() bounds,
    required String Function() contextLine,
    required Future<InputEvent> Function() readEvent,
    required void Function() hideOverlay,
    required void Function(void Function()?) setRepaint}) async {
  final picker = ModelSearchPicker(
      screen: screen,
      modelRefs: choices.refs,
      providerNames: choices.providerNames,
      modelNames: choices.modelNames,
      title: title,
      bounds: bounds,
      contextLine: contextLine,
      readEvent: readEvent,
      accent: screen.theme.border.focus);
  hideOverlay();
  setRepaint(picker.repaint);
  try {
    return await picker.run();
  } finally {
    setRepaint(null);
  }
}

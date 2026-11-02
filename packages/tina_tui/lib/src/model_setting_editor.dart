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
/// any model, so callers can fall back to another editor.
ModelChoices? modelChoices(
    ProviderDraft document, List<ProviderOption> descriptors, String current) {
  final providers = document.table('providers');
  final slash = current.indexOf('/');
  final currentId = slash > 0 ? current.substring(0, slash) : '';
  final currentModel = slash > 0 ? current.substring(slash + 1) : '';
  final ids = providers.isEmpty
      ? {
          ...descriptors.map((d) => d.id),
          if (currentId.isNotEmpty) currentId
        }.toList()
      : {
          ...providers.keys,
          if (currentId.isNotEmpty) currentId
        }.toList();
  final refs = <String>[];
  final names = <String, String>{};
  final modelNames = <String, String>{};
  for (final id in ids) {
    final descriptor = descriptors.where((d) => d.id == id).firstOrNull;
    final values = providers[id];
    final fields =
        (values as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final disabled =
        (fields['disabled_models'] as List? ?? const []).cast<String>();
    names[id] = fields['name'] as String? ?? descriptor?.name ?? id;
    final models = providerModels(descriptor, fields);
    for (final model in models.entries) {
      if (disabled.contains(model.key)) continue;
      refs.add('$id/${model.key}');
      modelNames['$id/${model.key}'] = model.value;
    }
    if (id == currentId &&
        currentModel.isNotEmpty &&
        !disabled.contains(currentModel) &&
        !refs.contains(current)) refs.add(current);
  }
  return refs.isEmpty
      ? null
      : (refs: refs, providerNames: names, modelNames: modelNames);
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

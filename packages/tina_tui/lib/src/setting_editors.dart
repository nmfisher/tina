import 'package:tina_console/tina_console.dart';
import 'package:tina_settings/tina_settings.dart';
import 'settings_management.dart';

/// A scoped-setting editor contributed by the application layer. Contributors
/// run before the panel's built-in editors: the first one that handles a
/// definition owns that edit. Editors produce a value — only the panel writes
/// it, through the scoped-settings path for the scope the user picked.
abstract interface class ScopedSettingEditor {
  bool handles(SettingInfo definition);

  /// Returns the edited value, or null when the user cancelled.
  Future<String?> edit(ScopedSettingEdit edit);
}

/// What the panel already has when a scoped edit starts: the definition, its
/// current value in the chosen scope, provider catalog access, the built-in
/// line editor for fallbacks, and the screen/frame utilities the panel's own
/// overlays use.
final class ScopedSettingEdit {
  ScopedSettingEdit(
      {required this.definition,
      required this.value,
      required this.scope,
      required this.providers,
      required this.openDraft,
      required this.closeDraft,
      required this.editText,
      required this.screen,
      required this.title,
      required this.bounds,
      required this.contextLine,
      required this.readEvent,
      required this.hideOverlay,
      required this.setRepaint});
  final SettingInfo definition;

  /// The setting's resolved value at [scope], as editable text.
  final String value;
  final SettingScope scope;

  /// The configured providers plus draft access to their public fields.
  final List<ProviderOption> providers;
  final ProviderDraft Function() openDraft;
  final void Function(ProviderDraft draft) closeDraft;

  /// The panel's built-in line editor, for contributors that cannot run
  /// their own widget and must keep the raw-value escape hatch.
  final Future<String?> Function(String label, String initial) editText;

  /// Screen and frame utilities: a contributor renders inside the panel's
  /// dialog frame and releases its overlay when done.
  final Screen screen;
  final String Function(String leaf) title;
  final Rect Function() bounds;
  final String Function() contextLine;
  final Future<InputEvent> Function() readEvent;
  final void Function() hideOverlay;
  final void Function(void Function()?) setRepaint;
}

import 'package:tina_console/tina_console.dart';

/// Presentation dependencies supplied by application composition. These create
/// attachment-local views; none exposes a host, plugin manager or store.
final class SessionPresentation {
  const SessionPresentation(
      {required this.theme,
      required this.configNote,
      required this.quitRequested,
      required this.createViews,
      required this.listenViews,
      required this.listenNotices,
      required this.listenTheme,
      required this.settingsFor});

  final Theme Function() theme;
  final String? configNote;
  final bool Function() quitRequested;
  final Map<String, ConsoleContribution> Function() createViews;
  final void Function() Function(
      void Function(String, ConsoleContribution) loaded,
      void Function(String) unloading) listenViews;
  final void Function() Function(void Function(String)) listenNotices;
  final void Function() Function(void Function(Theme)) listenTheme;
  final SessionSettingsView Function(ConsoleContext) settingsFor;
}

/// Attachment-local settings UI. The application supplies checked settings
/// operations and owns their configuration backend.
final class SessionSettingsView {
  const SessionSettingsView(
      {required this.open, required this.repaint, required this.close});
  final Future<String> Function() open;
  final void Function() repaint, close;
}

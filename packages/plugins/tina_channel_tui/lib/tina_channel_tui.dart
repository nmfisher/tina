/// tina_channel_tui — the read-only group-channel console pane.
///
/// The pane's session plugin (store ownership) lives in tina_channel;
/// this package is presentation only, wired through the console view
/// factories.
library;

export 'src/channel_pane.dart';
export 'src/channel_pane_view.dart';

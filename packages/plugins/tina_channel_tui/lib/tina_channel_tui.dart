/// tina_channel_tui — the group-channel console pane.
///
/// The pane's session plugin (store ownership and the human identity)
/// lives in tina_channel; this package is presentation only, wired
/// through the console view factories. The pane is interactive: with
/// it open, typing composes and Enter posts as the human through the
/// store interface.
library;

export 'src/channel_pane.dart';
export 'src/channel_pane_view.dart';

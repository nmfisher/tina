/// A live tokens-per-second gauge for tina's status bar.
///
/// Listens to the session's chat stream as the model responds, estimates the
/// output-token throughput over a short sliding window, and contributes a
/// `◔ N tok/s` status line while a turn is actively generating.
library;

export 'src/gauge.dart';
export 'src/token_rate_gauge_view.dart';

/// Terminal background color classification.
///
/// Used to pick a matching [Theme] variant at startup. See
/// [bgFromRgb] and the platform-seam's `bgFromPlatform` for the two
/// resolution strategies. The OSC-11 probe lives behind
/// `terminal_bg_probe.dart` (it touches stdin/stdout, which the wasm
/// guest does not own).
library;

/// Terminal background color classification.
enum TerminalBg { light, dark, unknown }

/// Choose a background scheme from an RGB luminance value.
///
/// Uses ITU-R BT.601 coefficients: L = 0.299*R + 0.587*G + 0.114*B.
/// Returns [TerminalBg.light] when luminance > 128, [TerminalBg.dark]
/// when luminance <= 128.
TerminalBg bgFromRgb(int r, int g, int b) {
  final luma = 0.299 * r + 0.587 * g + 0.114 * b;
  return luma > 128 ? TerminalBg.light : TerminalBg.dark;
}

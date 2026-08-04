import 'dart:async';
import 'dart:io' show Platform, stdin, stdout;

/// Terminal background color classification.
///
/// Used to pick a matching [Theme] variant at startup. See
/// [bgFromRgb] and [bgFromPlatform] for the two resolution strategies.
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

/// Platform-based heuristic when no probe result is available.
///
/// - macOS → [TerminalBg.light] (Terminal.app defaults to a white background)
/// - Linux → [TerminalBg.dark]  (GNOME Terminal, Konsole, xterm default to dark)
/// - Other → [TerminalBg.unknown]
TerminalBg bgFromPlatform() {
  if (Platform.isMacOS) return TerminalBg.light;
  if (Platform.isLinux) return TerminalBg.dark;
  return TerminalBg.unknown;
}

/// Probe the terminal background via OSC 11 (`ESC ] 11 ; ? ST`).
///
/// Writes the query to stdout, reads the response from stdin, and parses the
/// RGB value. Returns [TerminalBg.unknown] on timeout (terminal doesn't support
/// OSC 11) or parse failure.
///
/// The caller MUST have set raw mode on stdin before calling this function.
/// At that point no other stdin subscriber should be active.
///
/// If [probeStdin] is provided it is used instead of [stdin]. This allows the
/// caller to supply a broadcast-relay stream so that [AnsiInputBackend] can
/// also subscribe to stdin after the probe has consumed its first event
/// without hitting "Stream has already been listened to".
Future<TerminalBg> probeTerminalBg({
  Duration timeout = const Duration(milliseconds: 200),
  Stream<List<int>>? probeStdin,
}) async {
  // Send the OSC 11 query: ESC ] 11 ; ? ST (BEL-terminated for broad compat).
  stdout.write('\x1b]11;?\x07');

  try {
    final input = probeStdin ?? stdin;
    final bytes = await input.first.timeout(timeout);
    final bg = _parseOsc11(bytes);
    if (bg == null) return TerminalBg.unknown;
    return bgFromRgb(bg.r, bg.g, bg.b);
  } on TimeoutException {
    return TerminalBg.unknown;
  } catch (_) {
    return TerminalBg.unknown;
  }
}

/// Parse an OSC 11 response into an RGB triplet.
///
/// Two common formats:
///   `ESC ] 11 ; rgb:RRRR/GGGG/BBBB ST`  (xterm / GNOME Terminal)
///   `ESC ] 11 ; #RRGGBB ST`              (some terminals)
({int r, int g, int b})? _parseOsc11(List<int> raw) {
  final s = String.fromCharCodes(raw);

  // Find the payload after the semicolon: `ESC ] 11 ; <payload> ST`
  final semi = s.indexOf(';');
  if (semi < 0) return null;
  var payload = s.substring(semi + 1);

  // Strip trailing terminator (BEL \x07 or ST \x1b\\)
  final bel = payload.indexOf('\x07');
  if (bel >= 0) payload = payload.substring(0, bel);
  final st = payload.indexOf('\x1b\\');
  if (st >= 0) payload = payload.substring(0, st);

  payload = payload.trim();

  // Format: rgb:RRRR/GGGG/BBBB (1–4 hex digits per channel)
  final rgbMatch =
      RegExp(r'rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})')
          .firstMatch(payload);
  if (rgbMatch != null) {
    int parse(String h) {
      final v = int.parse(h, radix: 16);
      // Scale 16-bit to 8-bit if needed (take most significant bits)
      return h.length <= 2 ? v : (v >> 8) & 0xFF;
    }

    return (
      r: parse(rgbMatch.group(1)!),
      g: parse(rgbMatch.group(2)!),
      b: parse(rgbMatch.group(3)!),
    );
  }

  // Format: #RRGGBB or RRGGBB
  final hexMatch = RegExp(r'#?([0-9a-fA-F]{6})\b').firstMatch(payload);
  if (hexMatch != null) {
    final v = int.parse(hexMatch.group(1)!, radix: 16);
    return (r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF);
  }

  return null;
}

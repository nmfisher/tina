import '../styled_text.dart';

/// An optional backend capability for application-owned default colors.
abstract interface class CanvasBackend {
  void setCanvasStyle({required String foreground, required String background});
}

/// Rebase resets onto application colors without changing explicit text colors.
/// Shared by ANSI output and native planes; no terminal palette mutation needed.
class CanvasStyle {
  const CanvasStyle({this.foreground = '39', this.background = '49'});
  final String foreground;
  final String background;
  bool get isActive => foreground != '39' || background != '49';

  /// Hardware cursor color follows the explicit application foreground. SGR
  /// only colors cells; it cannot change a terminal profile's black cursor.
  String? get cursorColor {
    final rgb = parseStyledRuns('\x1b[${foreground}m ').last.style.fg;
    return rgb == null ? null : '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  static String cursorSequence(String? color) =>
      color == null ? '\x1b]112\x07' : '\x1b]12;$color\x07';
  String get reset => isActive ? '\x1b[0;$foreground;${background}m' : '';
  static final _sgr = RegExp(r'\x1b\[([0-9;]*)m');

  String apply(String text) {
    if (!isActive) return text;
    return reset +
        text.replaceAllMapped(_sgr, (match) {
          final parts = match[1]!.split(';');
          final result = <String>[];
          for (var i = 0; i < parts.length; i++) {
            final code = int.tryParse(parts[i]) ?? 0;
            switch (code) {
              case 0:
                result.addAll(['0', foreground, background]);
              case 39:
                result.add(foreground);
              case 49:
                result.add(background);
              case 38:
              case 48:
              case 58:
                // RGB and palette indices may themselves be 0, 39 or 49.
                final count = i + 1 < parts.length
                    ? switch (parts[i + 1]) { '2' => 4, '5' => 2, _ => 0 }
                    : 0;
                final end = (i + count + 1).clamp(0, parts.length);
                result.addAll(parts.sublist(i, end));
                i = end - 1;
              default:
                result.add(parts[i]);
            }
          }
          return '\x1b[${result.join(';')}m';
        });
  }
}

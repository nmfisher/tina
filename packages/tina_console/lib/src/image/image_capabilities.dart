/// Terminal image color capability for the ANSI (no pixel-protocol) path.
///
/// The notcurses backend never reads this - it uses notcurses's own
/// probes (`canPixel`/`canHalfBlock`/`pixelGeom`). This class answers the
/// weaker question for the pure-ANSI backend: how many colors can image
/// CELLS use, decided from the environment with an explicit override so
/// users and tests can pin it.
library;

enum ImageColorMode {
  /// Direct color SGR (38;2;r;g;b / 48;2;r;g;b).
  truecolor,

  /// xterm-256 palette with Floyd-Steinberg dithering.
  indexed256,

  /// No image colors: a readable placeholder instead of the image.
  mono,
}

final class ImageColorCapabilities {
  const ImageColorCapabilities._();

  /// Decide the color mode. Precedence:
  /// 1. [override] when it parses (`truecolor`/`direct`, `256`/`indexed`,
  ///    `off`/`mono`) - the documented escape hatch, e.g.
  ///    `TINA_IMAGE_COLOR=256`.
  /// 2. `COLORTERM` containing `truecolor` or `24bit` (or equal to
  ///    `yes`) - the de-facto direct-color signal.
  /// 3. `TERM` containing `direct` - direct color.
  /// 4. `TERM` containing `256color` - indexed.
  /// 5. otherwise mono.
  static ImageColorMode detect(
      {String? override, String? colorterm, String? term}) {
    switch (override?.trim().toLowerCase()) {
      case 'truecolor' || 'direct' || '24bit':
        return ImageColorMode.truecolor;
      case '256' || '256color' || 'indexed' || 'indexed256':
        return ImageColorMode.indexed256;
      case 'off' || 'mono' || 'none' || 'text':
        return ImageColorMode.mono;
      case null || '':
        break;
      default:
        // An unparsable override falls through to detection rather than
        // disabling images: a typo should not silently drop panels.
        break;
    }
    final colorTerm = colorterm?.toLowerCase() ?? '';
    if (colorTerm.contains('truecolor') ||
        colorTerm.contains('24bit') ||
        colorTerm == 'yes') {
      return ImageColorMode.truecolor;
    }
    final termValue = term?.toLowerCase() ?? '';
    if (termValue.contains('direct')) return ImageColorMode.truecolor;
    if (termValue.contains('256color')) return ImageColorMode.indexed256;
    return ImageColorMode.mono;
  }
}

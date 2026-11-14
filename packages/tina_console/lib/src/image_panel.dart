import 'dart:typed_data';

import 'backend/backend_surface.dart';
import 'console_contribution.dart';
import 'console_image.dart';
import 'panel_content.dart';
import 'region.dart';
import 'rect.dart';
import 'screen.dart';

/// What an image panel shows. Renderer-agnostic on purpose: this is the
/// contract the wasm TUI will consume later, so it carries only content
/// references (a file path or in-memory bytes) plus a label — never a
/// raster, backend or color mode.
///
/// Paths are the CALLER's responsibility: the native demo reads any path
/// it is given, while a sandboxed consumer resolves the path against its
/// granted directories before constructing the spec.
final class ImagePanelSpec {
  const ImagePanelSpec({this.path, this.bytes, required this.label})
      : assert(path != null || bytes != null, 'path or bytes required');

  /// File path of the image, resolved by the opener.
  final String? path;

  /// Raw encoded image bytes (any format `package:image` decodes).
  final Uint8List? bytes;

  /// Panel label / caption line.
  final String label;
}

/// Opens an image panel. Implemented by the panels workspace; plugins
/// reach it through [openImagePanel].
abstract interface class ImagePanelOpener {
  /// Decode [spec] and show it in a panel. Completes when the panel is
  /// mounted; the panel's lifetime is owned by the workspace.
  Future<void> openImagePanel(ImagePanelSpec spec);
}

/// Opens an image panel through [ConsoleContext.panels] when the active
/// workspace supports it. Returns false when no opener is attached (the
/// caller decides how to degrade).
Future<bool> openImagePanel(ConsoleContext context, ImagePanelSpec spec) async {
  final panels = context.panels;
  if (panels case ImagePanelOpener opener) {
    await opener.openImagePanel(spec);
    return true;
  }
  return false;
}

/// Panel content that shows one image plus a caption row.
///
/// Rendering is entirely the existing stack's: the image rides ordinary
/// [RegionLine]s as [ImageRow]s in a [ScrollingTextRegion], so the
/// notcurses backend blits it (pixel/half-block by its own probes) and
/// the ANSI backend renders half-block cells — this class only owns
/// geometry (re-fit on resize, re-use the fitted raster otherwise) and
/// the caption/status rows.
final class ImagePanelContent implements PanelContent {
  ImagePanelContent(this._screen, {required this.label});

  final Screen _screen;
  final String label;
  late final ScrollingTextRegion _region = ScrollingTextRegion(_screen);
  ConsoleImage? _image;
  Rect? _lastInterior;

  /// The decoded image to present. Triggers a re-fit on the next
  /// [fit]/[repaint]; the raster itself is cached by geometry inside
  /// [ConsoleImage.fit], so a resize re-scales exactly once per size.
  set image(ConsoleImage? value) {
    _image = value;
    _lastInterior = null;
  }

  ConsoleImage? get image => _image;

  @override
  void fit(Rect interior, {required bool reserveInputRow}) {
    if (_lastInterior == interior) return;
    _lastInterior = interior;
    // Same geometry contract as the chat adapter: bounds from the
    // surface override, the optional input row as a display-only inset.
    _region.setBoundsOverride(interior);
    _region.setBottomInset(reserveInputRow ? 1 : 0);
    _region.keepBottomInset = reserveInputRow;
    final usableHeight =
        interior.height - (reserveInputRow ? 1 : 0);
    final lines = <RegionLine>[RegionLine(label.isEmpty ? 'image' : label)];
    final image = _image;
    if (image == null || usableHeight < 3 || interior.width < 3) {
      lines.add(const RegionLine('(no image)'));
    } else {
      final raster = image.fit(
          columns: interior.width - 1,
          rows: usableHeight - 2,
          cells: _screen.imageCellSize ?? ImageCellSize.halfBlock);
      for (var row = 0; row < raster.rows; row++) {
        lines.add(RegionLine(' ', image: ImageRow(raster, row, column: 1)));
      }
    }
    _region.rewriteFrom(0, lines);
  }

  @override
  void attach() => _region.attach();

  @override
  void detach() => _region.detach();

  @override
  bool get isDetached => _region.isDetached;

  @override
  BackendSurface? get surface => _region.surface;

  @override
  void bindSurface(BackendSurface? s) => _region.bindSurface(s);

  @override
  void repaint() => _region.repaint();
}

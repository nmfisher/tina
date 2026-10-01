import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'backend/backend_surface.dart';

/// Decoded pixels owned by the presentation layer, never by the agent loop.
final class ConsoleImage {
  ConsoleImage._(this._image);
  final img.Image _image;
  final _fits = <(int, int, ImageCellSize), ImageRaster>{};
  int get width => _image.width;
  int get height => _image.height;

  /// Decode the first frame. Bad or excessively large attachments stay text
  /// placeholders rather than interrupting the conversation.
  static ConsoleImage? decode(Uint8List bytes) {
    try {
      if (bytes.length > 32 * 1024 * 1024) return null;
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null || info.width * info.height > 16 * 1024 * 1024) {
        return null;
      }
      final image = decoder!.decodeFrame(0);
      return image == null
          ? null
          : ConsoleImage._(img.bakeOrientation(image.convert(
              format: img.Format.uint8, numChannels: 4, noAnimation: true)));
    } catch (_) {
      return null;
    }
  }

  ImageRaster fit(
      {required int columns, required int rows, required ImageCellSize cells}) {
    columns = math.max(1, columns);
    rows = math.max(1, rows);
    final key = (columns, rows, cells);
    return _fits.putIfAbsent(key, () {
      // A bounded cache keeps resize/repaint cheap without retaining every
      // geometry a terminal has ever had.
      if (_fits.length >= 4) _fits.clear();
      final scale = math.min(
          1.0,
          math.min(
              columns * cells.width / width, rows * cells.height / height));
      final w = math.max(1, (width * scale).floor());
      final h = math.max(1, (height * scale).floor());
      final fitted = img.copyResize(_image,
          width: w, height: h, interpolation: img.Interpolation.average);
      final bytes = fitted.getBytes(order: img.ChannelOrder.rgba);
      // Own an aligned buffer: Uint8List views can start at a nonzero offset.
      final rgba = Uint32List(w * h);
      rgba.buffer.asUint8List().setAll(0, bytes);
      return ImageRaster(rgba: rgba, width: w, height: h, cells: cells);
    });
  }
}

/// Source pixels per terminal cell for the chosen graphics blitter.
final class ImageCellSize {
  const ImageCellSize(this.width, this.height);
  final int width, height;
  static const halfBlock = ImageCellSize(1, 2);
  @override
  bool operator ==(Object other) =>
      other is ImageCellSize && width == other.width && height == other.height;
  @override
  int get hashCode => Object.hash(width, height);
}

final class ImageRaster {
  ImageRaster(
      {required this.rgba,
      required this.width,
      required this.height,
      required this.cells}) {
    if (width < 1 ||
        height < 1 ||
        rgba.length < width * height ||
        cells.width < 1 ||
        cells.height < 1) {
      throw ArgumentError('Invalid image geometry or RGBA buffer');
    }
  }
  final Uint32List rgba;
  final int width, height;
  final ImageCellSize cells;
  int get columns => (width + cells.width - 1) ~/ cells.width;
  int get rows => (height + cells.height - 1) ~/ cells.height;
}

/// One retained transcript row of an image. Cropping happens at the viewport,
/// so scrolling can reveal the middle of an image without covering the input.
final class ImageRow {
  const ImageRow(this.image, this.index, {this.column = 0});
  final ImageRaster image;
  final int index, column;
}

/// A visible, vertically cropped image in absolute terminal coordinates.
final class ImagePlacement {
  const ImagePlacement(
      {required this.image,
      required this.row,
      required this.column,
      required this.sourceRow,
      required this.rows,
      required this.columns});
  final ImageRaster image;
  final int row, column, sourceRow, rows, columns;
  @override
  bool operator ==(Object other) =>
      other is ImagePlacement &&
      identical(image, other.image) &&
      row == other.row &&
      column == other.column &&
      sourceRow == other.sourceRow &&
      rows == other.rows &&
      columns == other.columns;
  @override
  int get hashCode => Object.hash(image, row, column, sourceRow, rows, columns);
}

/// Optional graphics capability. Text-only backends keep readable captions.
abstract interface class RetainedImageBackend {
  ImageCellSize get imageCellSize;
  bool updateImages(Object owner, List<ImagePlacement> images,
      {BackendSurface? targetSurface});
  void clearImages(Object owner);
}

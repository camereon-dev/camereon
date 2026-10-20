import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'hide_region.dart';
import 'photo_images.dart';
import 'photo_processor.dart';

/// `package:image` を使った [PhotoProcessor] の実装。
class ImagePhotoProcessor implements PhotoProcessor {
  const ImagePhotoProcessor({this.jpegQuality = 95});

  final int jpegQuality;

  @override
  Future<SourcePhoto> normalize(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw const FormatException('Unsupported image format');
    }

    final normalized = img.bakeOrientation(decoded)..exif = img.ExifData();
    final bytes = img.encodeJpg(normalized, quality: jpegQuality);

    return SourcePhoto(
      bytes: bytes,
      width: normalized.width,
      height: normalized.height,
    );
  }

  @override
  Future<RedactedJpeg> redact(SourcePhoto photo, List<HideRegion> regions) async {
    final decoded = img.decodeImage(photo.bytes);
    if (decoded == null) {
      throw const FormatException('Unsupported image format');
    }

    for (final region in regions) {
      final left = region.left.clamp(0, decoded.width).toInt();
      final top = region.top.clamp(0, decoded.height).toInt();
      final right = region.right.clamp(0, decoded.width).toInt();
      final bottom = region.bottom.clamp(0, decoded.height).toInt();
      if (left >= right || top >= bottom) continue;

      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          decoded.setPixelRgba(x, y, 0, 0, 0, 255);
        }
      }
    }

    decoded.exif = img.ExifData();
    final bytes = img.encodeJpg(decoded, quality: jpegQuality);

    return RedactedJpeg(
      bytes: bytes,
      width: decoded.width,
      height: decoded.height,
    );
  }
}

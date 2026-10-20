import 'dart:typed_data';
import 'dart:ui';

import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/image_photo_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _jpegWithExifOrientationAndThumbnail() {
  final image = img.Image(width: 3, height: 2);
  image.setPixelRgba(0, 0, 255, 0, 0, 255); // 赤
  image.setPixelRgba(1, 0, 0, 255, 0, 255); // 緑
  image.setPixelRgba(2, 0, 0, 0, 255, 255); // 青
  image.setPixelRgba(0, 1, 255, 255, 0, 255); // 黄
  image.setPixelRgba(1, 1, 255, 255, 255, 255); // 白
  image.setPixelRgba(2, 1, 255, 0, 255, 255); // 紫

  image.exif.imageIfd.orientation = 6;
  image.exif.imageIfd.make = 'camereon-test';
  image.exif.exifIfd['DateTimeOriginal'] = '2026:10:20 00:00:00';
  image.exif.thumbnailData = img.encodeJpg(img.Image(width: 1, height: 1), quality: 95);

  return img.encodeJpg(image, quality: 95);
}

void main() {
  const processor = ImagePhotoProcessor(jpegQuality: 100);

  test('normalize は EXIF 向きを画素へ反映し、EXIF を含まない JPEG を返す', () async {
    final input = _jpegWithExifOrientationAndThumbnail();
    final inputExif = img.decodeJpgExif(input);
    final normalized = await processor.normalize(input);
    final image = img.decodeJpg(normalized.bytes);

    expect(inputExif, isNotNull);
    expect(inputExif!.thumbnailData, isNotNull);
    expect(image, isNotNull);
    expect(normalized.width, 2);
    expect(normalized.height, 3);
    expect(image!.width, 2);
    expect(image.height, 3);
    expect(img.decodeJpgExif(normalized.bytes), isNull);
  });

  test('redact は元画像サイズのまま範囲を不透明な黒で焼き込む', () async {
    final source = await processor.normalize(_jpegWithExifOrientationAndThumbnail());
    final regions = [
      HideRegion.fromRect(
        const Rect.fromLTRB(0, 0, 1, 1),
        imageWidth: source.width,
        imageHeight: source.height,
      )!,
      HideRegion.fromRect(
        const Rect.fromLTRB(1, 2, 2, 3),
        imageWidth: source.width,
        imageHeight: source.height,
      )!,
    ];

    final redacted = await processor.redact(source, regions);
    final image = img.decodeJpg(redacted.bytes);

    expect(redacted.width, source.width);
    expect(redacted.height, source.height);
    expect(image, isNotNull);
    expect(image!.width, source.width);
    expect(image.height, source.height);

    final topLeft = image.getPixel(0, 0);
    final bottomRight = image.getPixel(1, 2);
    final center = image.getPixel(1, 1);
    expect(topLeft.r, lessThanOrEqualTo(8));
    expect(topLeft.g, lessThanOrEqualTo(8));
    expect(topLeft.b, lessThanOrEqualTo(8));
    expect(bottomRight.r, lessThanOrEqualTo(8));
    expect(bottomRight.g, lessThanOrEqualTo(8));
    expect(bottomRight.b, lessThanOrEqualTo(8));
    expect(center.r + center.g + center.b, greaterThan(24));
    expect(img.decodeJpgExif(redacted.bytes), isNull);
  });
}

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/image_photo_processor.dart';
import 'package:camereon/core/photo/photo_processing_exception.dart';
import 'package:camereon/features/analysis/prepare_analysis_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../support/photo_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final processor = FlutterPhotoProcessor();

  for (var orientation = 1; orientation <= 8; orientation++) {
    test(
      'device JPEG orientation $orientation matches analysis and exports clean pixels',
      () async {
        final input = metadataJpeg(orientation: orientation);
        final source = await processor.normalize(input);
        final analysis = await prepareAnalysisImage(input);
        expect(
          (source.width, source.height),
          (analysis.width, analysis.height),
        );
        expect((
          source.width,
          source.height,
        ), orientation >= 5 ? (32, 48) : (48, 32));
        expect(
          pngChunks(source.bytes),
          everyElement(isIn(['IHDR', 'sBIT', 'sRGB', 'IDAT', 'IEND'])),
        );
        expect(() => source.bytes[0] = 0, throwsUnsupportedError);
        final jpeg = await processor.redact(source, [
          HideRegion.fromRect(
            const Rect.fromLTRB(0, 0, 16, 16),
            imageWidth: source.width,
            imageHeight: source.height,
          )!,
        ]);
        final pixels = img.decodeJpg(jpeg.bytes)!;
        expect(pixels.getPixel(8, 8).luminance, lessThan(3));
        expect(pixels.exif.isEmpty, isTrue);
        expect(pixels.exif.thumbnailData, isNull);
        expect(
          jpegSegments(jpeg.bytes).map((s) => s.marker),
          everyElement(isIn([0xe0, 0xdb, 0xc0, 0xc4, 0xda])),
        );
      },
    );
  }

  test(
    'platform-readable JPEG with repeated camera EXIF can be edited',
    () async {
      final image = colorGrid();
      image.exif.imageIfd.orientation = 6;
      final jpeg = img.encodeJpg(image);
      final exif = jpegSegments(jpeg).firstWhere((s) => s.marker == 0xe1);
      final input = Uint8List.fromList([
        ...jpeg.take(2),
        ...segment(0xe1, exif.data),
        ...jpeg.skip(2),
      ]);
      await expectLater(
        ImagePhotoProcessor().normalize(input),
        throwsA(isA<PhotoProcessingException>()),
      );
      final source = await processor.normalize(input);
      final analysis = await prepareAnalysisImage(input);
      expect((source.width, source.height), (analysis.width, analysis.height));
      expect((source.width, source.height), (32, 48));
      expect(
        pngChunks(source.bytes),
        everyElement(isIn(['IHDR', 'sBIT', 'sRGB', 'IDAT', 'IEND'])),
      );
    },
  );

  test('invalid input and pixel/byte limits still fail safely', () async {
    final input = img.encodePng(colorGrid());
    for (final attempt in [
      () => processor.normalize(Uint8List(0)),
      () => processor.normalize(Uint8List.fromList([1, 2, 3])),
      () => FlutterPhotoProcessor(maxPixels: 100).normalize(input),
      () => FlutterPhotoProcessor(maxInputBytes: 10).normalize(input),
    ]) {
      await expectLater(attempt(), throwsA(isA<PhotoProcessingException>()));
    }
  });
}

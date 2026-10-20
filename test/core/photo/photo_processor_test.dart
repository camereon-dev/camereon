import 'dart:typed_data';
import 'dart:ui';

import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/image_photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_processing_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../support/photo_fixtures.dart';

Matcher failure(PhotoProcessingFailure reason) =>
    isA<PhotoProcessingException>().having((e) => e.reason, 'reason', reason);

HideRegion region(int l, int t, int r, int b, int width, int height) =>
    HideRegion.fromRect(
      Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()),
      imageWidth: width,
      imageHeight: height,
    )!;

void main() {
  final processor = ImagePhotoProcessor();
  final expected = {
    1: [0, 1, 2, 3, 4, 5],
    2: [2, 1, 0, 5, 4, 3],
    3: [5, 4, 3, 2, 1, 0],
    4: [3, 4, 5, 0, 1, 2],
    5: [0, 3, 1, 4, 2, 5],
    6: [3, 0, 4, 1, 5, 2],
    7: [5, 2, 4, 1, 3, 0],
    8: [2, 5, 1, 4, 0, 3],
  };

  for (final orientation in expected.keys) {
    test('PNG eXIf $orientation を正規化し、再正規化しても向きが変わらない', () async {
      final source = await processor.normalize(orientedPng(orientation));
      final width = orientation >= 5 ? 32 : 48;
      final height = orientation >= 5 ? 48 : 32;
      expect((source.width, source.height), (width, height));
      final decoded = img.decodePng(source.bytes)!;
      final reference = colorGrid();
      for (var i = 0; i < 6; i++) {
        final index = expected[orientation]![i];
        final actual = decoded.getPixel(
          (i % (width ~/ 16)) * 16 + 8,
          (i ~/ (width ~/ 16)) * 16 + 8,
        );
        final original = reference.getPixel(
          (index % 3) * 16 + 8,
          (index ~/ 3) * 16 + 8,
        );
        expect(
          [actual.r, actual.g, actual.b],
          [original.r, original.g, original.b],
        );
      }
      expect((await processor.normalize(source.bytes)).bytes, source.bytes);
    });

    test('EXIF $orientation の回転・反転・寸法を正規化し同じ座標を隠す', () async {
      final source = await processor.normalize(
        metadataJpeg(orientation: orientation),
      );
      final width = orientation >= 5 ? 32 : 48;
      final height = orientation >= 5 ? 48 : 32;
      expect((source.width, source.height), (width, height));
      final decoded = img.decodePng(source.bytes)!;
      final reference = colorGrid();
      for (var i = 0; i < 6; i++) {
        final index = expected[orientation]![i];
        final actual = decoded.getPixel(
          (i % (width ~/ 16)) * 16 + 8,
          (i ~/ (width ~/ 16)) * 16 + 8,
        );
        final original = reference.getPixel(
          (index % 3) * 16 + 8,
          (index ~/ 3) * 16 + 8,
        );
        expect(actual.r, closeTo(original.r, 3));
        expect(actual.g, closeTo(original.g, 3));
        expect(actual.b, closeTo(original.b, 3));
      }
      final jpeg = await processor.redact(source, [
        region(0, 0, 16, 16, width, height),
      ]);
      final redacted = img.decodeJpg(jpeg.bytes)!;
      expect((redacted.width, redacted.height), (width, height));
      expect(redacted.getPixel(8, 8).luminance, lessThanOrEqualTo(2));
      expect(
        redacted.getPixel(width - 8, height - 8).luminance,
        greaterThan(10),
      );
    });
  }

  test('EXIF・未加工サムネイル・XMP・IPTC・コメント・末尾データを除去', () async {
    final input = metadataJpeg();
    final original = img.decodeJpg(input)!;
    expect(original.exif.imageIfd.make, 'FICTIONAL-CAMERA');
    expect(original.exif.gpsIfd.gpsLatitude, 12);
    expect(original.exif.exifIfd[0x9003].toString(), '2000:01:02 03:04:05');
    expect(original.exif.thumbnailData, isNotEmpty);
    expect(() => jpegSegments(input), throwsFormatException);
    final source = await processor.normalize(input);
    expect(
      pngChunks(source.bytes),
      everyElement(isIn(['IHDR', 'IDAT', 'IEND'])),
    );
    final output = await processor.redact(source, []);
    final segments = jpegSegments(output.bytes);
    expect(
      segments.map((s) => s.marker),
      everyElement(isIn([0xe0, 0xdb, 0xc0, 0xc4, 0xda])),
    );
    final app0 = segments.singleWhere((s) => s.marker == 0xe0).data;
    expect(app0.take(5), 'JFIF\x00'.codeUnits);
    expect(app0.length, 14);
    expect(app0.sublist(12), [0, 0]); // JFIF サムネイルの幅・高さ
    final decoded = img.decodeJpg(output.bytes)!;
    expect(decoded.exif.isEmpty, isTrue);
    expect(decoded.exif.thumbnailData, isNull);
    expect(decoded.iccProfile, isNull);
  });

  for (final size in [(19, 31), (31, 19), (17, 17), (1, 1)]) {
    test('Orientationなし ${size.$1} x ${size.$2} の解像度を維持', () async {
      final input = img.Image(width: size.$1, height: size.$2);
      img.fill(input, color: img.ColorRgb8(255, 255, 255));
      final source = await processor.normalize(img.encodeJpg(input));
      final jpeg = await processor.redact(source, [
        region(0, 0, size.$1, size.$2, size.$1, size.$2),
      ]);
      expect((jpeg.width, jpeg.height), size);
      final decoded = img.decodeJpg(jpeg.bytes)!;
      for (final p in decoded) {
        expect(p.luminance, lessThanOrEqualTo(2));
      }
    });
  }

  test('隠す範囲内だけが違う入力の最終JPEGは完全に一致する', () async {
    final first = colorGrid();
    final second = colorGrid();
    img.fillRect(
      second,
      x1: 7,
      y1: 3,
      x2: 28,
      y2: 26,
      color: img.ColorRgb8(123, 45, 67),
    );
    final a = await processor.normalize(img.encodePng(first));
    final b = await processor.normalize(img.encodePng(second));
    final regions = [region(7, 3, 29, 27, 48, 32)];
    expect(
      (await processor.redact(a, regions)).bytes,
      (await processor.redact(b, regions)).bytes,
    );
  });

  test('入力を変更せず、受付後の変更を処理へ反映しない', () async {
    final bytes = img.encodePng(colorGrid());
    final original = Uint8List.fromList(bytes);
    final source = await processor.normalize(bytes);
    expect(bytes, original);
    expect(() => source.bytes[0] = 0, throwsUnsupportedError);
    final mutable = Uint8List.fromList(source.bytes);
    final regions = [region(0, 0, 48, 32, 48, 32)];
    final pending = processor.redact(
      SourcePhoto(bytes: mutable, width: 48, height: 32),
      regions,
    );
    mutable.fillRange(0, mutable.length, 0);
    regions.clear();
    final result = await pending;
    expect(
      img.decodeJpg(result.bytes)!.getPixel(24, 16).luminance,
      lessThan(2),
    );
    expect(() => result.bytes[0] = 0, throwsUnsupportedError);
    final reset = await processor.redact(source, []);
    expect(
      img.decodeJpg(reset.bytes)!.getPixel(24, 16).luminance,
      greaterThan(10),
    );
    final pendingNormalize = processor.normalize(bytes);
    bytes.fillRange(0, bytes.length, 0);
    expect((await pendingNormalize).bytes, source.bytes);
  });

  test('透過PNGは白へ合成し、テキストメタデータを除去', () async {
    final image = img.Image(width: 3, height: 1, numChannels: 4);
    image.textData = {'Comment': 'FICTIONAL-SECRET'};
    image.setPixelRgba(0, 0, 255, 0, 0, 0);
    image.setPixelRgba(1, 0, 0, 0, 0, 128);
    image.setPixelRgba(2, 0, 0, 0, 0, 255);
    final input = img.encodePng(image);
    expect(pngChunks(input), contains('tEXt'));
    final source = await processor.normalize(input);
    final decoded = img.decodePng(source.bytes)!;
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(1, 0).r, 127);
    expect(decoded.getPixel(2, 0).r, 0);
    expect(
      pngChunks(source.bytes),
      everyElement(isIn(['IHDR', 'IDAT', 'IEND'])),
    );
  });

  test('空・未対応形式・破損画像はisolateから失敗を返す', () async {
    await expectLater(
      processor.normalize(Uint8List(0)),
      throwsA(failure(PhotoProcessingFailure.invalidImage)),
    );
    await expectLater(
      processor.normalize(Uint8List.fromList([1, 2, 3])),
      throwsA(failure(PhotoProcessingFailure.unsupportedFormat)),
    );
    await expectLater(
      processor.normalize(Uint8List.fromList([255, 216, 0])),
      throwsA(failure(PhotoProcessingFailure.invalidImage)),
    );
    final png = img.encodePng(colorGrid());
    await expectLater(
      processor.normalize(png.sublist(0, 30)),
      throwsA(failure(PhotoProcessingFailure.invalidImage)),
    );
  });

  test('アニメーションPNGを拒否', () async {
    final animated = colorGrid()..addFrame(colorGrid());
    await expectLater(
      processor.normalize(img.encodePng(animated)),
      throwsA(failure(PhotoProcessingFailure.unsupportedFormat)),
    );
  });

  test('不正なPNG Orientationや未正規化SourcePhotoを拒否', () async {
    await expectLater(
      processor.normalize(orientedPng(9)),
      throwsA(failure(PhotoProcessingFailure.invalidImage)),
    );
    await expectLater(
      processor.redact(
        SourcePhoto(bytes: orientedPng(6), width: 48, height: 32),
        [],
      ),
      throwsA(failure(PhotoProcessingFailure.invalidSource)),
    );
  });

  test('寸法不一致・別画像用の範囲を拒否する', () async {
    final source = await processor.normalize(img.encodePng(colorGrid()));
    await expectLater(
      processor.redact(
        SourcePhoto(bytes: source.bytes, width: 47, height: 32),
        [],
      ),
      throwsA(failure(PhotoProcessingFailure.invalidSource)),
    );
    await expectLater(
      processor.redact(source, [region(45, 0, 49, 20, 100, 100)]),
      throwsA(failure(PhotoProcessingFailure.invalidRegion)),
    );
  });

  test('バイト数・画素数上限をJPEG/PNGで検査し、縮小しない', () async {
    for (final bytes in [
      img.encodeJpg(colorGrid()),
      img.encodePng(colorGrid()),
    ]) {
      await expectLater(
        ImagePhotoProcessor(maxPixels: 100).normalize(bytes),
        throwsA(failure(PhotoProcessingFailure.imageTooLarge)),
      );
      await expectLater(
        ImagePhotoProcessor(maxInputBytes: 10).normalize(bytes),
        throwsA(failure(PhotoProcessingFailure.imageTooLarge)),
      );
    }
    expect(() => ImagePhotoProcessor(maxPixels: 0), throwsArgumentError);
  });
}

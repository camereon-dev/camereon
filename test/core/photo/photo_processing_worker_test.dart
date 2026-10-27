import 'package:camereon/core/photo/photo_processing_exception.dart';
import 'package:camereon/core/photo/src/photo_processing_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../support/photo_fixtures.dart';

void main() {
  test('半開区間・四隅・1画素・重複を全画素で確認し、範囲外は変更しない', () {
    final original = colorGrid();
    final image = copyPixels(original);
    final regions = [
      (left: 0, top: 0, right: 1, bottom: 1),
      (left: 47, top: 0, right: 48, bottom: 1),
      (left: 0, top: 31, right: 1, bottom: 32),
      (left: 47, top: 31, right: 48, bottom: 32),
      (left: 7, top: 4, right: 8, bottom: 30),
      (left: 10, top: 5, right: 30, bottom: 6),
      (left: 20, top: 5, right: 40, bottom: 12),
      (left: 40, top: 5, right: 47, bottom: 12),
    ];
    paintRegions(image, regions);
    for (final p in image) {
      final hidden = regions.any(
        (r) => p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom,
      );
      final before = original.getPixel(p.x, p.y);
      expect(
        [p.r, p.g, p.b],
        hidden ? [0, 0, 0] : [before.r, before.g, before.b],
        reason: 'pixel (${p.x}, ${p.y})',
      );
      expect(p.aNormalized, 1);
    }
  });

  test('全領域を検査してから描画し、不正領域を黙って省かない', () {
    final image = colorGrid();
    final before = image.getBytes().toList();
    expect(
      () => paintRegions(image, [
        (left: 0, top: 0, right: 48, bottom: 32),
        (left: -1, top: 0, right: 2, bottom: 2),
      ]),
      throwsA(isA<PhotoProcessingException>()),
    );
    expect(image.getBytes(), before);
  });

  test('PNGのOrientationも補正してからメタデータを取り除く', () {
    final input = orientedPng(6);
    expect(pngChunks(input), contains('eXIf'));
    final result = normalizePixels(input, 10000);
    expect((result.width, result.height), (32, 48));
    final decoded = img.decodePng(result.bytes)!;
    final p = decoded.getPixel(8, 8);
    expect([p.r, p.g, p.b], [240, 240, 20]);
    expect(
      pngChunks(result.bytes),
      everyElement(isIn(['IHDR', 'IDAT', 'IEND'])),
    );
  });
}

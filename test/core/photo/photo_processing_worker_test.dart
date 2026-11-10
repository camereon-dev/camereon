import 'dart:typed_data';

import 'package:camereon/core/photo/photo_processing_exception.dart';
import 'package:camereon/core/photo/src/photo_processing_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../support/photo_fixtures.dart';

PixelShape rect(int left, int top, int right, int bottom) => (
  left: left,
  top: top,
  right: right,
  bottom: bottom,
  shape: 0,
  points: Float64List(0),
);

void main() {
  test('半開区間・四隅・1画素・重複の内側を置き換え、縁の外側だけをなじませる', () {
    final original = colorGrid();
    final regions = [
      rect(0, 0, 1, 1),
      rect(47, 0, 48, 1),
      rect(0, 31, 1, 32),
      rect(47, 31, 48, 32),
      rect(7, 4, 8, 30),
      rect(10, 5, 30, 6),
      rect(20, 5, 40, 12),
      rect(40, 5, 47, 12),
    ];
    final image = paintRegions(copyPixels(original), regions);
    expect((image.width, image.height), (48, 32));
    var changedInside = 0;
    for (final p in image) {
      final hidden = regions.any(
        (r) => p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom,
      );
      final near = regions.any(
        (r) =>
            p.x >= r.left - 3 &&
            p.x < r.right + 3 &&
            p.y >= r.top - 3 &&
            p.y < r.bottom + 3,
      );
      final before = original.getPixel(p.x, p.y);
      if (!near) {
        expect(
          [p.r, p.g, p.b],
          [before.r, before.g, before.b],
          reason: 'pixel (${p.x}, ${p.y}) is far from every region',
        );
      }
      if (hidden && (p.r != before.r || p.g != before.g || p.b != before.b)) {
        changedInside++;
      }
      // Never black: the fill comes from the surrounding colors.
      if (hidden) expect(p.r + p.g + p.b, greaterThan(30));
      expect(p.aNormalized, 1);
    }
    // The saturated grid differs from any blend of neighbours almost everywhere.
    expect(changedInside, greaterThan(180));
  });

  test('全領域を検査してから描画し、不正領域を黙って省かない', () {
    final image = colorGrid();
    final before = image.getBytes().toList();
    for (final invalid in [
      rect(-1, 0, 2, 2),
      rect(0, 0, 49, 2),
      rect(5, 5, 5, 9),
      (left: 0, top: 0, right: 4, bottom: 4, shape: 3, points: Float64List(0)),
      (
        left: 0,
        top: 0,
        right: 4,
        bottom: 4,
        shape: 2,
        points: Float64List.fromList([0, 0, 4, 0]),
      ),
    ]) {
      expect(
        () => paintRegions(image, [rect(0, 0, 48, 32), invalid]),
        throwsA(isA<PhotoProcessingException>()),
      );
    }
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

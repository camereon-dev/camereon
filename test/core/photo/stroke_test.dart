import 'dart:typed_data';
import 'dart:ui';

import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/image_photo_processor.dart';
import 'package:camereon/core/photo/src/frosted_fill.dart';
import 'package:flutter_test/flutter_test.dart';

HideRegion stroke(List<Offset> points, double radius, {bool reveal = false}) =>
    HideRegion.stroke(
      points,
      radius,
      imageWidth: 96,
      imageHeight: 48,
      reveal: reveal,
    )!;

HideRegion rect(Rect r) =>
    HideRegion.fromRect(r, imageWidth: 96, imageHeight: 48)!;

/// A busy pattern: any fill differs from the original at nearly every pixel.
Uint8List pattern(int w, int h) {
  final px = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    px[i * 3] = (i * 37) % 256;
    px[i * 3 + 1] = (i * 91) % 256;
    px[i * 3 + 2] = (i * 13) % 256;
  }
  return px;
}

bool changed(Uint8List a, Uint8List b, int x, int y, int w) {
  final i = (y * w + x) * 3;
  return a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2];
}

void main() {
  group('HideRegion.stroke', () {
    test('bounds cover the radius and are clamped to the image', () {
      final s = stroke([const Offset(2, 10), const Offset(40, 10)], 5);
      expect((s.left, s.top, s.right, s.bottom), (0, 5, 45, 15));
      expect(s.shape, HideShape.stroke);
      expect(s.reveal, isFalse);
    });

    test('contains follows the capsule, not the bounding box', () {
      final s = stroke([const Offset(10, 10), const Offset(40, 40)], 4);
      expect(s.contains(const Offset(25, 25)), isTrue);
      expect(s.contains(const Offset(10, 13.5)), isTrue);
      expect(s.toRect().contains(const Offset(38, 12)), isTrue);
      expect(s.contains(const Offset(38, 12)), isFalse);
      expect(s.toPath().contains(const Offset(25, 25)), isTrue);
      expect(s.toPath().contains(const Offset(38, 12)), isFalse);
    });

    test('a single point is a dot', () {
      final dot = stroke([const Offset(20, 20)], 3);
      expect(dot.contains(const Offset(22, 20)), isTrue);
      expect(dot.contains(const Offset(24, 20)), isFalse);
    });

    test('rejects empty, invalid or off-image strokes', () {
      HideRegion? make(List<Offset> p, double r) =>
          HideRegion.stroke(p, r, imageWidth: 96, imageHeight: 48);
      expect(make(const [], 3), isNull);
      expect(make(const [Offset(1, 1)], 0), isNull);
      expect(make(const [Offset(1, 1)], double.nan), isNull);
      expect(make(const [Offset(double.infinity, 1)], 3), isNull);
      expect(make(const [Offset(-50, -50)], 3), isNull);
    });

    test('pen and eraser over the same path are different regions', () {
      final path = [const Offset(10, 10), const Offset(20, 20)];
      expect(stroke(path, 3), isNot(stroke(path, 3, reveal: true)));
      expect(stroke(path, 3), stroke(List.of(path), 3));
    });
  });

  group('frostShapes with strokes', () {
    const w = 96, h = 48;
    List<PixelShape> shapes(List<HideRegion> r) => [
      for (final region in r) pixelShape(region),
    ];

    test('a pen stroke hides every pixel of its capsule', () {
      final original = pattern(w, h);
      final out = Uint8List.fromList(original);
      final s = stroke([const Offset(10, 24), const Offset(80, 24)], 6);
      frostShapes(out, w, h, 3, shapes([s]));
      final mask = rasterize(pixelShape(s), 0, 0, w, h);
      var inside = 0, hidden = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (mask[y * w + x] == 0) continue;
          inside++;
          if (changed(original, out, x, y, w)) hidden++;
        }
      }
      expect(inside, greaterThan(700));
      expect(hidden, greaterThan(inside * .97));
      // Far from the stroke nothing changes.
      expect(changed(original, out, 40, 2, w), isFalse);
    });

    test('an eraser leaves the pixels it crosses untouched', () {
      final original = pattern(w, h);
      final out = Uint8List.fromList(original);
      final box = rect(const Rect.fromLTRB(10, 10, 80, 40));
      final eraser = stroke(
        [const Offset(45, 0), const Offset(45, 48)],
        8,
        reveal: true,
      );
      frostShapes(out, w, h, 3, shapes([box, eraser]));
      for (var y = 10; y < 40; y++) {
        // Every pixel inside the eraser stays original, including its edge.
        for (var x = 37; x < 53; x++) {
          expect(changed(original, out, x, y, w), isFalse, reason: '($x,$y)');
        }
        // Still hidden outside the eraser.
        expect(changed(original, out, 20, y, w), isTrue);
        expect(changed(original, out, 70, y, w), isTrue);
      }
    });

    test('a pen after the eraser hides that place again', () {
      final original = pattern(w, h);
      final out = Uint8List.fromList(original);
      final box = rect(const Rect.fromLTRB(10, 10, 80, 40));
      final eraser = stroke(
        [const Offset(45, 0), const Offset(45, 48)],
        8,
        reveal: true,
      );
      final pen = stroke([const Offset(30, 25), const Offset(60, 25)], 4);
      frostShapes(out, w, h, 3, shapes([box, eraser, pen]));
      expect(changed(original, out, 45, 25, w), isTrue);
      expect(changed(original, out, 45, 15, w), isFalse);
    });

    test('an eraser alone or first changes nothing', () {
      final original = pattern(w, h);
      final out = Uint8List.fromList(original);
      final eraser = stroke([const Offset(45, 24)], 10, reveal: true);
      frostShapes(out, w, h, 3, shapes([eraser]));
      expect(out, original);
    });

    test('hidden content never leaks into the fill, erased content may', () {
      // Changing pixels that end up hidden must not change the output.
      final box = rect(const Rect.fromLTRB(10, 10, 80, 40));
      final eraser = stroke(
        [const Offset(45, 0), const Offset(45, 48)],
        8,
        reveal: true,
      );
      final pen = stroke([const Offset(30, 25), const Offset(60, 25)], 4);
      final ops = shapes([box, eraser, pen]);
      final hidden = Uint8List(w * h);
      for (final op in ops) {
        final m = rasterize(op, 0, 0, w, h);
        for (var i = 0; i < m.length; i++) {
          if (m[i] != 0) hidden[i] = op.reveal ? 0 : 1;
        }
      }
      final first = pattern(w, h);
      final second = Uint8List.fromList(first);
      for (var i = 0; i < hidden.length; i++) {
        if (hidden[i] == 0) continue;
        second[i * 3] = 255;
        second[i * 3 + 1] = 0;
        second[i * 3 + 2] = 255;
      }
      frostShapes(first, w, h, 3, ops);
      frostShapes(second, w, h, 3, ops);
      expect(second, first);
    });
  });
}

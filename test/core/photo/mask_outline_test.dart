import 'dart:typed_data';
import 'dart:ui';

import 'package:camereon/core/photo/mask_outline.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List disc(int size, double radius) {
  final mask = Uint8List(size * size);
  final c = (size - 1) / 2;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final d = ((x - c) * (x - c) + (y - c) * (y - c));
      // Soft edge so interpolation has something to work with.
      final v = (radius + .5 - d.sqrtValue()).clamp(0.0, 1.0);
      mask[y * size + x] = (v * 255).round();
    }
  }
  return mask;
}

extension on num {
  double sqrtValue() => this <= 0 ? 0 : _sqrt(toDouble());
}

double _sqrt(double v) {
  var x = v;
  for (var i = 0; i < 30; i++) {
    x = (x + v / x) / 2;
  }
  return x;
}

void main() {
  test('a disc traces to a closed outline with area close to the circle', () {
    final outline = traceMask(disc(32, 10), 32, 32)!;
    expect(outline.length, greaterThan(8));
    var area = 0.0;
    for (var i = 0, j = outline.length - 1; i < outline.length; j = i++) {
      area += outline[j].dx * outline[i].dy - outline[i].dx * outline[j].dy;
    }
    expect(area.abs() / 2, closeTo(3.14159 * 100, 25));
    for (final p in outline) {
      expect(p.dx, inInclusiveRange(0, 32));
      expect(p.dy, inInclusiveRange(0, 32));
    }
  });

  test('the largest of several blobs wins and empty masks return null', () {
    final mask = Uint8List(16 * 16);
    for (var y = 1; y < 4; y++) {
      for (var x = 1; x < 4; x++) {
        mask[y * 16 + x] = 255;
      }
    }
    for (var y = 6; y < 15; y++) {
      for (var x = 6; x < 15; x++) {
        mask[y * 16 + x] = 255;
      }
    }
    final outline = traceMask(mask, 16, 16)!;
    final xs = outline.map((p) => p.dx);
    expect(xs.reduce((a, b) => a < b ? a : b), greaterThan(4));
    expect(traceMask(Uint8List(16 * 16), 16, 16), isNull);
    expect(maskCoverage(mask, 16, 16), closeTo((9 + 81) / 256, 1e-9));
  });

  test('a mask touching the border still closes and maps into bounds', () {
    final mask = Uint8List(8 * 8)..fillRange(0, 8 * 8, 255);
    final outline = traceMask(mask, 8, 8)!;
    expect(outline.length, greaterThanOrEqualTo(4));
    final mapped = mapOutline(
      outline,
      8,
      8,
      const Rect.fromLTRB(100, 200, 180, 280),
    );
    for (final p in mapped) {
      expect(p.dx, inInclusiveRange(95, 185));
      expect(p.dy, inInclusiveRange(195, 285));
    }
  });
}

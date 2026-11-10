import 'dart:typed_data';

import 'package:camereon/core/photo/src/frosted_fill.dart';
import 'package:flutter_test/flutter_test.dart';

PixelShape shape(
  int shape,
  int left,
  int top,
  int right,
  int bottom, [
  List<double> points = const [],
]) => (
  left: left,
  top: top,
  right: right,
  bottom: bottom,
  shape: shape,
  points: Float64List.fromList(points),
);

/// Two flat halves: dark left, light right, with a thin bright stripe inside
/// the area to be hidden so hidden content is visibly distinct from any fill.
Uint8List halves(int w, int h) {
  final px = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      final light = x >= w ~/ 2;
      px[i] = light ? 200 : 40;
      px[i + 1] = light ? 190 : 60;
      px[i + 2] = light ? 170 : 90;
    }
  }
  return px;
}

void main() {
  test('rasterize: ellipse and polygon cover their shape, not the box', () {
    final ellipse = rasterize(shape(1, 0, 0, 40, 20), 0, 0, 40, 20);
    expect(ellipse[10 * 40 + 20], 1, reason: 'center');
    expect(ellipse[0], 0, reason: 'corner outside the ellipse');
    expect(ellipse[1 * 40 + 20], 1, reason: 'top of the vertical axis');
    final triangle = rasterize(
      shape(2, 0, 0, 40, 40, [0, 0, 40, 0, 0, 40]),
      0,
      0,
      40,
      40,
    );
    expect(triangle[2 * 40 + 2], 1, reason: 'near the right-angle corner');
    expect(triangle[37 * 40 + 37], 0, reason: 'far corner outside');
    var count = 0;
    for (final v in triangle) {
      count += v;
    }
    expect(count, closeTo(800, 40));
    // A window offset from the shape origin maps the same pixels.
    final shifted = rasterize(shape(0, 10, 10, 14, 12), 8, 9, 10, 6);
    expect(shifted[(10 - 9) * 10 + (10 - 8)], 1);
    expect(shifted[0], 0);
  });

  test('inside pixels come only from the surroundings; outside stays', () {
    const w = 96, h = 48;
    final px = halves(w, h);
    // Paint a bright stripe through the hidden area: it must vanish.
    for (var y = 20; y < 28; y++) {
      for (var x = 30; x < 66; x++) {
        final i = (y * w + x) * 3;
        px[i] = 255;
        px[i + 1] = 0;
        px[i + 2] = 255;
      }
    }
    final before = Uint8List.fromList(px);
    frostShapes(px, w, h, 3, [shape(1, 28, 12, 68, 36)]);
    for (var y = 20; y < 28; y++) {
      for (var x = 32; x < 64; x++) {
        final i = (y * w + x) * 3;
        expect(px[i + 1], greaterThan(40), reason: 'magenta stripe removed');
        expect(px[i], lessThan(230));
      }
    }
    // Left part of the hidden area leans dark, right part light.
    final leftI = (24 * w + 34) * 3, rightI = (24 * w + 62) * 3;
    expect(px[leftI], lessThan(px[rightI]));
    // Far outside pixels are untouched (feather is at most a few pixels).
    for (var y = 0; y < h; y++) {
      for (final x in [0, 10, 85, 95]) {
        final i = (y * w + x) * 3;
        expect(
          [px[i], px[i + 1], px[i + 2]],
          [before[i], before[i + 1], before[i + 2]],
        );
      }
    }
    // Deterministic.
    final again = Uint8List.fromList(before);
    frostShapes(again, w, h, 3, [shape(1, 28, 12, 68, 36)]);
    expect(again, px);
  });

  test('covering the whole image falls back to neutral grey', () {
    const w = 8, h = 8;
    final px = halves(w, h);
    frostShapes(px, w, h, 3, [shape(0, 0, 0, w, h)]);
    expect(px.every((v) => v == 128), isTrue);
  });

  test('RGBA buffers keep alpha and only touch colour channels', () {
    const w = 16, h = 16;
    final px = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      px[i * 4] = 10;
      px[i * 4 + 1] = 200;
      px[i * 4 + 2] = 30;
      px[i * 4 + 3] = 255;
    }
    frostShapes(px, w, h, 4, [shape(0, 4, 4, 12, 12)]);
    for (var i = 0; i < w * h; i++) {
      expect(px[i * 4 + 3], 255);
      // A flat image keeps its colour: nothing but the same green around.
      expect((px[i * 4 + 1] - 200).abs(), lessThan(12));
    }
  });

  test('overlay layers are transparent outside the shape and its feather', () {
    const w = 96, h = 48;
    final px = halves(w, h);
    final before = Uint8List.fromList(px);
    final layer = frostOverlay(px, w, h, 3, shape(1, 28, 12, 68, 36))!;
    expect(px, before, reason: 'the source is read only');
    // The layer covers only the shape plus a few feather pixels.
    expect(layer.left, inInclusiveRange(20, 28));
    expect(layer.left + layer.width, inInclusiveRange(68, 76));
    int alphaAt(int x, int y) =>
        layer.rgba[((y - layer.top) * layer.width + (x - layer.left)) * 4 + 3];
    expect(alphaAt(48, 24), 255, reason: 'centre of the ellipse');
    expect(alphaAt(layer.left, layer.top), 0, reason: 'corner of the layer');
    // Premultiplied: no channel exceeds alpha.
    for (var i = 0; i < layer.rgba.length; i += 4) {
      final a = layer.rgba[i + 3];
      expect(layer.rgba[i], lessThanOrEqualTo(a));
      expect(layer.rgba[i + 1], lessThanOrEqualTo(a));
      expect(layer.rgba[i + 2], lessThanOrEqualTo(a));
    }
    // Compositing the layer gives the same pixels as painting in place.
    final inPlace = Uint8List.fromList(before);
    frostShapes(inPlace, w, h, 3, [shape(1, 28, 12, 68, 36)]);
    for (var y = layer.top; y < layer.top + layer.height; y++) {
      for (var x = layer.left; x < layer.left + layer.width; x++) {
        final o = ((y - layer.top) * layer.width + (x - layer.left)) * 4;
        final a = layer.rgba[o + 3] / 255;
        for (var c = 0; c < 3; c++) {
          final composed =
              layer.rgba[o + c] + before[(y * w + x) * 3 + c] * (1 - a);
          expect(composed, closeTo(inPlace[(y * w + x) * 3 + c], 2));
        }
      }
    }
  });
}

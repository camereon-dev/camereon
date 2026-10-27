import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:image/image.dart' as img;

/// Evaluation baseline only; not imported by the production application.
class EdgeDensityDetector implements RegionDetector {
  @override
  Future<RegionDetection> detect(SourcePhoto photo) async {
    final data = Uint8List.fromList(photo.bytes);
    final boxes = await Isolate.run(() => _detect(data));
    return RegionDetection(
      candidates: [
        for (final b in boxes)
          if (HideRegion.fromRect(
                Rect.fromLTRB(b[0], b[1], b[2], b[3]),
                imageWidth: photo.width,
                imageHeight: photo.height,
              )
              case final region?)
            RegionCandidate(kind: CandidateKind.text, region: region),
      ],
    );
  }
}

List<List<double>> _detect(Uint8List bytes) {
  final original = img.decodePng(bytes)!;
  final scale = math.min(1.0, 960 / math.max(original.width, original.height));
  final image = img.copyResize(
    original,
    width: (original.width * scale).round(),
    height: (original.height * scale).round(),
  );
  const cell = 24;
  final columns = (image.width / cell).ceil();
  final rows = (image.height / cell).ceil();
  final active = List.filled(columns * rows, false);
  for (var cy = 0; cy < rows; cy++) {
    for (var cx = 0; cx < columns; cx++) {
      var horizontal = 0;
      var vertical = 0;
      var count = 0;
      for (
        var y = cy * cell + 1;
        y < math.min((cy + 1) * cell, image.height - 1);
        y++
      ) {
        for (
          var x = cx * cell + 1;
          x < math.min((cx + 1) * cell, image.width - 1);
          x++
        ) {
          final dx =
              (image.getPixel(x + 1, y).luminance -
                      image.getPixel(x - 1, y).luminance)
                  .abs();
          final dy =
              (image.getPixel(x, y + 1).luminance -
                      image.getPixel(x, y - 1).luminance)
                  .abs();
          if (dx > 70) horizontal++;
          if (dy > 70) vertical++;
          count++;
        }
      }
      final density = (horizontal + vertical) / math.max(1, count * 2);
      final balance = horizontal / math.max(1, vertical);
      active[cy * columns + cx] =
          density >= .10 && density <= .65 && balance > .2 && balance < 5;
    }
  }
  final boxes = <List<double>>[];
  for (var i = 0; i < active.length; i++) {
    if (!active[i]) continue;
    final queue = [i];
    active[i] = false;
    var left = columns;
    var right = 0;
    var top = rows;
    var bottom = 0;
    for (var head = 0; head < queue.length; head++) {
      final x = queue[head] % columns;
      final y = queue[head] ~/ columns;
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
      for (final (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]) {
        if (nx < 0 || ny < 0 || nx >= columns || ny >= rows) continue;
        final next = ny * columns + nx;
        if (active[next]) {
          active[next] = false;
          queue.add(next);
        }
      }
    }
    if (queue.length < 2) continue;
    boxes.add([
      left * cell / scale,
      top * cell / scale,
      math.min(image.width, (right + 1) * cell) / scale,
      math.min(image.height, (bottom + 1) * cell) / scale,
    ]);
  }
  return boxes;
}

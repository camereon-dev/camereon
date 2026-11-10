import 'dart:ui';

import 'package:camereon/core/photo/hide_region.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ellipse keeps outward-rounded bounds and tests the oval, not the box',
    () {
      final face = HideRegion.ellipse(
        const Rect.fromLTRB(10.4, 20.6, 50.2, 80.1),
        imageWidth: 100,
        imageHeight: 100,
      )!;
      expect(face.shape, HideShape.ellipse);
      expect(face.toRect(), const Rect.fromLTRB(10, 20, 51, 81));
      expect(face.contains(const Offset(30, 50)), isTrue);
      expect(face.contains(const Offset(11, 21)), isFalse);
      expect(
        face,
        isNot(
          HideRegion.fromRect(
            const Rect.fromLTRB(10, 20, 51, 81),
            imageWidth: 100,
            imageHeight: 100,
          ),
        ),
      );
    },
  );

  test('polygon clamps vertices into the image and derives its bounds', () {
    final tilted = HideRegion.polygon(
      const [Offset(-5, 10), Offset(60, 0), Offset(70, 20), Offset(5, 30)],
      imageWidth: 64,
      imageHeight: 40,
    )!;
    expect(tilted.shape, HideShape.polygon);
    expect(tilted.points.first, const Offset(0, 10));
    expect(tilted.points[2], const Offset(64, 20));
    expect(tilted.toRect(), const Rect.fromLTRB(0, 0, 64, 30));
    expect(tilted.contains(const Offset(30, 15)), isTrue);
    expect(tilted.contains(const Offset(2, 1)), isFalse);
    expect(
      tilted,
      HideRegion.polygon(
        const [Offset(0, 10), Offset(60, 0), Offset(64, 20), Offset(5, 30)],
        imageWidth: 64,
        imageHeight: 40,
      ),
    );
    expect(
      tilted,
      isNot(
        HideRegion.polygon(
          const [Offset(0, 10), Offset(60, 0), Offset(64, 20), Offset(6, 30)],
          imageWidth: 64,
          imageHeight: 40,
        ),
      ),
    );
  });

  test('degenerate polygons are rejected', () {
    for (final points in [
      const [Offset(0, 0), Offset(10, 10)],
      const [Offset(0, 0), Offset(10, 0), Offset(20, 0)],
      const [Offset(double.nan, 0), Offset(10, 0), Offset(0, 10)],
      const [Offset(70, 70), Offset(80, 70), Offset(80, 80)],
    ]) {
      expect(
        HideRegion.polygon(points, imageWidth: 64, imageHeight: 64),
        isNull,
        reason: '$points',
      );
    }
  });

  test('paths follow the shape', () {
    final rect = HideRegion.fromRect(
      const Rect.fromLTRB(0, 0, 10, 10),
      imageWidth: 10,
      imageHeight: 10,
    )!;
    final oval = HideRegion.ellipse(
      const Rect.fromLTRB(0, 0, 10, 10),
      imageWidth: 10,
      imageHeight: 10,
    )!;
    expect(rect.toPath().contains(const Offset(.5, .5)), isTrue);
    expect(oval.toPath().contains(const Offset(.5, .5)), isFalse);
    expect(oval.toPath().contains(const Offset(5, 5)), isTrue);
  });
}

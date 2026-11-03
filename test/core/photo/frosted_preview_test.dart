import 'dart:ui';

import 'package:camereon/core/photo/frosted_preview.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('patches cover the region window at preview scale', (
    tester,
  ) async {
    final image = img.Image(width: 400, height: 200);
    img.fill(image, color: img.ColorRgb8(30, 90, 200));
    img.fillRect(
      image,
      x1: 150,
      y1: 50,
      x2: 250,
      y2: 150,
      color: img.ColorRgb8(250, 250, 250),
    );
    final photo = SourcePhoto(
      bytes: img.encodePng(image),
      width: 400,
      height: 200,
    );
    final previewer = IsolateFrostedPreviewer(maxSide: 200);
    final region = HideRegion.ellipse(
      const Rect.fromLTRB(150, 50, 250, 150),
      imageWidth: 400,
      imageHeight: 200,
    )!;
    await tester.runAsync(() async {
      await previewer.load(photo);
      expect(previewer.isLoaded, isTrue);
      final patch = (await previewer.patch(region))!;
      expect(patch.region, region);
      // The window encloses the region in source coordinates.
      expect(patch.bounds.left, lessThanOrEqualTo(150));
      expect(patch.bounds.right, greaterThanOrEqualTo(250));
      expect(patch.bounds.top, lessThanOrEqualTo(50));
      expect(patch.bounds.bottom, greaterThanOrEqualTo(150));
      // Preview pixels are half scale (maxSide 200 for a 400px photo).
      expect(patch.image.width, closeTo(patch.bounds.width / 2, 1.5));
      final data = (await patch.image.toByteData())!;
      final w = patch.image.width;
      final cx = ((200 - patch.bounds.left) / 2).round();
      final cy = ((100 - patch.bounds.top) / 2).round();
      final i = (cy * w + cx) * 4;
      // The white block is gone; the centre takes the blue surroundings.
      expect(data.getUint8(i + 2), greaterThan(150));
      expect(data.getUint8(i), lessThan(90));
      patch.dispose();
      previewer.dispose();
      expect(await previewer.patch(region), isNull);
      expect(await const FrostedPreviewer.none().patch(region), isNull);
    });
  });

  testWidgets('a patch never repaints a neighbouring hidden area', (
    tester,
  ) async {
    // Two people side by side: hiding B must not paint A's original pixels.
    final image = img.Image(width: 400, height: 200);
    img.fill(image, color: img.ColorRgb8(30, 90, 200));
    img.fillRect(
      image,
      x1: 60,
      y1: 40,
      x2: 140,
      y2: 160,
      color: img.ColorRgb8(250, 30, 30),
    );
    img.fillRect(
      image,
      x1: 180,
      y1: 40,
      x2: 260,
      y2: 160,
      color: img.ColorRgb8(30, 250, 30),
    );
    final photo = SourcePhoto(
      bytes: img.encodePng(image),
      width: 400,
      height: 200,
    );
    final previewer = IsolateFrostedPreviewer(maxSide: 400);
    final b = HideRegion.fromRect(
      const Rect.fromLTRB(180, 40, 260, 160),
      imageWidth: 400,
      imageHeight: 200,
    )!;
    await tester.runAsync(() async {
      await previewer.load(photo);
      final patch = (await previewer.patch(b))!;
      final data = (await patch.image.toByteData())!;
      final w = patch.image.width;
      int alphaAt(double x, double y) {
        final px = (x - patch.bounds.left).floor();
        final py = (y - patch.bounds.top).floor();
        if (px < 0 || py < 0 || px >= w || py >= patch.image.height) return 0;
        return data.getUint8((py * w + px) * 4 + 3);
      }

      expect(alphaAt(220, 100), 255, reason: 'B itself is covered');
      // A's interior is transparent in B's patch, wherever B's bounds reach.
      for (final x in [70.0, 100.0, 130.0, 160.0]) {
        expect(alphaAt(x, 100), 0, reason: 'x=$x');
      }
      patch.dispose();
      previewer.dispose();
    });
  });
}

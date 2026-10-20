import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/support/photo_fixtures.dart';

class RecordingSaver implements PhotoSaver {
  final delegate = AndroidPhotoSaver();
  RedactedJpeg? saved;
  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    final result = await delegate.save(jpeg);
    if (result is SaveSucceeded) saved = jpeg;
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'oriented photograph: edit, confirm, save JPEG, retake and clean up',
    (tester) async {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/CAP-integration.jpg');
      await file.writeAsBytes(metadataJpeg(orientation: 6));
      final saver = RecordingSaver();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CapturedPhotoScreen(
                      photo: XFile(file.path),
                      saver: saver,
                    ),
                  ),
                ),
                child: const Text('テスト写真を開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('テスト写真を開く'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('撮影した写真'), findsOneWidget);
      final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
      final gesture = await tester.startGesture(
        rect.topLeft + Offset(rect.width * .1, rect.height * .1),
      );
      await gesture.moveTo(
        rect.topLeft + Offset(rect.width * .6, rect.height * .6),
      );
      await gesture.up();
      await tester.pump();
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is CustomPaint &&
                          widget.painter is SelectionPainter,
                    ),
                  )
                  .painter!
              as SelectionPainter;
      final HideRegion region = painter.regions.single;
      expect((painter.imageWidth, painter.imageHeight), (32, 48));
      await tester.tap(find.text('保存前に確認'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('保存する加工済み写真'), findsOneWidget);
      await tester.tap(find.text('写真に保存'));
      await tester.pumpAndSettle();
      expect(find.text('写真を保存しました'), findsOneWidget);
      final jpeg = saver.saved!;
      expect((jpeg.width, jpeg.height), (32, 48));
      final image = img.decodeJpg(jpeg.bytes)!;
      expect(image.exif.isEmpty, isTrue);
      expect(image.exif.thumbnailData, isNull);
      expect(
        image
            .getPixel(
              (region.left + region.right) ~/ 2,
              (region.top + region.bottom) ~/ 2,
            )
            .luminance,
        lessThan(3),
      );
      expect(image.getPixel(28, 44).luminance, greaterThan(10));
      expect(
        jpegSegments(jpeg.bytes).map((s) => s.marker),
        everyElement(isIn([0xe0, 0xdb, 0xc0, 0xc4, 0xda])),
      );
      await tester.tap(find.text('もう一枚'));
      await tester.pumpAndSettle();
      expect(find.text('テスト写真を開く'), findsOneWidget);
      expect(await file.exists(), isFalse);
    },
  );
}

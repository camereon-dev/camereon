import 'dart:io';
import 'dart:ui' as ui;

import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import '../test/support/photo_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const normalizer = MethodChannel('dev.camereon/image_normalizer');
  testWidgets('iOS: oriented input -> pixels -> redacted JPEG -> Photos', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue, reason: 'This test requires iOS.');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (final orientation in [1, 3, 6, 8]) {
      final input = metadataJpeg(orientation: orientation);
      final normalized = await normalizer.invokeMethod<Uint8List>(
        'normalize',
        input,
      );
      expect(normalized, isNotNull);
      final processor = FlutterPhotoProcessor();
      final source = await processor.normalize(normalized!);
      expect((
        source.width,
        source.height,
      ), orientation >= 5 ? (32, 48) : (48, 32));
      final region = HideRegion.fromRect(
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        imageWidth: source.width,
        imageHeight: source.height,
      )!;
      final jpeg = await processor.redact(source, [region]);
      final decoded = img.decodeJpg(jpeg.bytes)!;
      expect(decoded.exif.imageIfd.isEmpty, isTrue);
      expect(decoded.exif.gpsIfd.isEmpty, isTrue);
      expect(decoded.getPixel(10, 10).r, closeTo(128, 2));
      if (orientation == 6) {
        expect(await AndroidPhotoSaver().save(jpeg), isA<SaveSucceeded>());
      }
    }
    await expectLater(
      normalizer.invokeMethod<Uint8List>('normalize', Uint8List(3)),
      throwsA(isA<PlatformException>()),
    );
    expect(
      await const MethodChannel('dev.camereon/photo_saver')
          .invokeMethod<String>('save', {'bytes': Uint8List(3)}),
      'failed',
    );
  });
  testWidgets('iOS: nominal 24MP input keeps 4284 x 5712 pixels through save', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xff337799), BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(4284, 5712);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final input = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final normalized = await normalizer.invokeMethod<Uint8List>(
      'normalize',
      input,
    );
    final processor = FlutterPhotoProcessor();
    final source = await processor.normalize(normalized!);
    expect((source.width, source.height), (4284, 5712));
    final region = HideRegion.fromRect(
      const Rect.fromLTWH(100, 100, 400, 400),
      imageWidth: source.width,
      imageHeight: source.height,
    )!;
    final jpeg = await processor.redact(source, [region]);
    expect((jpeg.width, jpeg.height), (4284, 5712));
    expect(await AndroidPhotoSaver().save(jpeg), isA<SaveSucceeded>());
  });
}

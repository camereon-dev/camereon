import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iPhone: real camera capture, normalize, redact and save', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('撮影テスト中：保存する画像は全体を隠します'))),
      ),
    );
    final cameras = await availableCameras();
    expect(cameras, isNotEmpty, reason: 'A real iPhone camera is required.');
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
    );
    XFile? capture;
    try {
      await controller.initialize();
      capture = await controller.takePicture();
      expect(await File(capture.path).exists(), isTrue);
      final processor = FlutterPhotoProcessor();
      final source = await processor.normalize(await capture.readAsBytes());
      expect(source.width, greaterThan(0));
      expect(source.height, greaterThan(0));
      final region = HideRegion.fromRect(
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        imageWidth: source.width,
        imageHeight: source.height,
      )!;
      final jpeg = await processor.redact(source, [region]);
      expect(await AndroidPhotoSaver().save(jpeg), isA<SaveSucceeded>());
    } finally {
      await controller.dispose();
      if (capture != null && await File(capture.path).exists()) {
        await File(capture.path).delete();
      }
    }
  });
}

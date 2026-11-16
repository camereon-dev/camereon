import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import '../test/support/photo_editor.dart' as editor;

Uint8List fixture({bool phone = true}) {
  final image = img.Image(width: 1000, height: 500);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  final lines = [
    'NAME: SAMPLE',
    if (phone) 'TEL: 090-0000-0000' else 'REF: 1234567',
    'ZIP: 000-0000',
    'DATE: 2026-11-16',
  ];
  for (var i = 0; i < lines.length; i++) {
    img.drawString(
      image,
      lines[i],
      font: img.arial48,
      x: 40,
      y: 40 + i * 100,
      color: img.ColorRgb8(0, 0, 0),
    );
  }
  return img.encodePng(image);
}

int darkPixels(img.Image image, Rect rect) {
  var count = 0;
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      final pixel = image.getPixel(x, y);
      if (pixel.r < 80 && pixel.g < 80 && pixel.b < 80) count++;
    }
  }
  return count;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real offline OCR masks phone digits while preserving names and dates',
    (tester) async {
      final processor = FlutterPhotoProcessor();
      final source = await processor.normalize(fixture());
      final result = await AndroidTextRegionDetector(detailed: false)
          .detect(source);
      expect(result.partial, isFalse);
      final phones = result.candidates
          .where((c) => c.kind == CandidateKind.phone)
          .toList();
      expect(phones, hasLength(1));
      expect(
        result.candidates.any((c) => c.kind == CandidateKind.text),
        isTrue,
      );
      final box = phones.single.region.toRect();
      expect(
        box.left,
        greaterThan(130),
        reason: 'TEL label must remain outside the phone mask',
      );
      expect(box.top, inInclusiveRange(120, 175));
      expect(box.bottom, lessThan(210));
      final jpeg = await processor.redact(source, [phones.single.region]);
      final original = img.decodePng(source.bytes)!;
      final saved = img.decodeJpg(jpeg.bytes)!;
      expect((saved.width, saved.height), (source.width, source.height));
      expect(darkPixels(original, box), greaterThan(100));
      expect(darkPixels(saved, box), lessThan(darkPixels(original, box) * .1));
      for (final untouched in [
        const Rect.fromLTRB(40, 35, 650, 100),
        const Rect.fromLTRB(40, 235, 650, 300),
        const Rect.fromLTRB(40, 335, 650, 400),
        const Rect.fromLTRB(40, 135, 130, 200),
      ]) {
        expect(
          darkPixels(saved, untouched),
          greaterThan(darkPixels(original, untouched) * .9),
        );
      }
      expect(await AndroidPhotoSaver().save(jpeg), isA<SaveSucceeded>());
      final control = await processor.normalize(fixture(phone: false));
      final noPhones = await AndroidTextRegionDetector(detailed: false)
          .detect(control);
      expect(noPhones.partial, isFalse);
      expect(
        noPhones.candidates.where((c) => c.kind == CandidateKind.phone),
        isEmpty,
      );
      expect(
        noPhones.candidates.where((c) => c.kind == CandidateKind.text),
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'real detection automatically selects only phones in the editor',
    (tester) async {
      final saver = editor.FakeSaver();
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(fixture()),
            faceDetector: editor.NoFaces(),
            objectDetector: editor.NoRegions(),
            saver: saver,
            sharer: editor.FakeSharer(),
          ),
        ),
      );
      var ready = false;
      for (var i = 0; i < 600; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        final overlay = find.byType(CandidateOverlay);
        if (overlay.evaluate().isNotEmpty &&
            tester
                .widget<CandidateOverlay>(overlay)
                .candidates
                .any((c) => c.kind == CandidateKind.phone) &&
            find.text('検出中').evaluate().isEmpty) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue);
      await tester.pumpAndSettle();
      final candidates = editor.overlay(tester);
      expect(candidates.selectedCandidates, hasLength(1));
      expect(candidates.selectedCandidates.single.kind, CandidateKind.phone);
      expect(
        candidates.candidates.where((c) => c.kind == CandidateKind.text),
        isNotEmpty,
      );
      // pumpAndSettle does not wait for an isolate's image-generation future.
      for (var i = 0; i < 300 && editor.painter(tester).patches.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(editor.painter(tester).patches, isNotEmpty);
      if (const bool.fromEnvironment('PHONE_REDACTION_SCREENSHOT')) {
        debugPrint('PHONE_AUTO_REDACTION_READY');
        await Future<void>.delayed(const Duration(seconds: 15));
      }
      await editor.tapText(tester, '保存前に確認');
      for (var i = 0; i < 300 && find.text('写真に保存').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await editor.tapText(tester, '写真に保存');
      expect(saver.calls, 1);
      expect(saver.received, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:camereon/core/detection/japanese_address_detector.dart';
import 'package:camereon/core/detection/japanese_phone_number_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'editor_support.dart';

class _RecordingOcr implements RegionDetector {
  RegionDetection? result;
  @override
  Future<RegionDetection> detect(SourcePhoto photo) async =>
      result = await JapaneseAddressDetector().detect(photo);
}

class _RecordingSaver implements PhotoSaver {
  RedactedJpeg? saved;
  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    final result = await AndroidPhotoSaver().save(jpeg);
    if (result is SaveSucceeded) saved = jpeg;
    return result;
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for native OCR, image processing or gallery save');
}

Future<Uint8List> _syntheticPhoto() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
  // Artificial test values only. No subscriber information or real contact list.
  const rows = [
    '電話番号:090-0000-1234',
    'TEL:03 0000 5678',
    '050 0000 4321',
    '携帯:＋８１ ９０ ００００ ９８７６',
    'TEL:12345678',
    'TEL:123-4567',
    '管理番号:09000009999',
    '日付:2026-11-17',
    '郵便番号:100-0001',
    '東京都新宿区西新宿2丁目8番1号',
    'NAME: SAMPLE',
  ];
  for (var i = 0; i < rows.length; i++) {
    final painter = TextPainter(
      text: TextSpan(
        text: rows[i],
        style: const TextStyle(
          color: Colors.black,
          fontSize: 36,
          fontFamily: 'sans-serif',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 1120);
    painter.paint(canvas, Offset(40, 35 + i * 90));
    painter.dispose();
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1200, 1080);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

double _darkPixels(img.Image image, Rect region) {
  var count = 0;
  for (
    var y = region.top.ceil().clamp(0, image.height);
    y < region.bottom.floor().clamp(0, image.height);
    y++
  ) {
    for (
      var x = region.left.ceil().clamp(0, image.width);
      x < region.right.floor().clamp(0, image.width);
      x++
    ) {
      if (image.getPixel(x, y).luminance < 100) count++;
    }
  }
  return count.toDouble();
}

Future<Directory> _evidence() async {
  final root = await getApplicationSupportDirectory();
  return Directory('${root.path}/phone-v2-evidence')
    ..createSync(recursive: true);
}

Rect _drawnNumberBounds(int row, String prefix, String number) {
  TextPainter measure(String text) => TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        color: Colors.black,
        fontSize: 36,
        fontFamily: 'sans-serif',
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 1120);
  final before = measure(prefix);
  final full = measure('$prefix$number');
  final rect = Rect.fromLTWH(
    40 + before.width,
    35 + row * 90,
    full.width - before.width,
    full.height,
  );
  before.dispose();
  full.dispose();
  return rect;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'parcel sample: actual OCR masks only phone digits and keeps address detector',
    (tester) async {
      final sourceBytes = (await rootBundle.load(
        'tools/vlm-eval/fixtures/parcel_ja.png',
      )).buffer.asUint8List();
      final processor = FlutterPhotoProcessor();
      final source = await processor.normalize(sourceBytes);
      final detection = await JapaneseAddressDetector().detect(source);
      final phones = detection.candidates
          .whereType<PhoneNumberCandidate>()
          .toList();
      expect(phones, hasLength(1));
      expect(phones.single.automaticallySelected, isTrue);
      expect(
        detection.candidates.any((c) => c.kind == CandidateKind.address),
        isTrue,
      );
      final jpeg = await processor.redact(source, [phones.single.region]);
      final before = img.decodePng(source.bytes)!;
      final after = img.decodeJpg(jpeg.bytes)!;
      final box = phones.single.region.toRect();
      expect(_darkPixels(before, box), greaterThan(50));
      expect(_darkPixels(after, box), lessThan(_darkPixels(before, box) * .05));
      expect(
        _darkPixels(after, const Rect.fromLTRB(142, 390, 315, 420)),
        lessThan(5),
      );
      for (final preserved in [
        const Rect.fromLTRB(80, 270, 300, 300),
        const Rect.fromLTRB(80, 330, 440, 360),
        const Rect.fromLTRB(80, 390, 130, 420),
      ]) {
        final original = _darkPixels(before, preserved);
        expect(original, greaterThan(20));
        expect(_darkPixels(after, preserved), closeTo(original, original * .1));
      }
      final evidence = await _evidence();
      await File('${evidence.path}/parcel-phone-only.jpg')
          .writeAsBytes(jpeg.bytes);
    },
  );

  testWidgets(
    'synthetic photo: automatic and optional candidates toggle and save offline',
    (tester) async {
      final bytes = await _syntheticPhoto();
      final detector = _RecordingOcr();
      final saver = _RecordingSaver();
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(bytes),
            addressDetector: detector,
            saver: saver,
          ),
        ),
      );
      await _until(
        tester,
        () =>
            find.byType(CandidateOverlay).evaluate().isNotEmpty &&
            detector.result != null,
      );
      await tester.pumpAndSettle();
      var overlay = tester.widget<CandidateOverlay>(
        find.byType(CandidateOverlay),
      );
      final phones = overlay.candidates
          .whereType<PhoneNumberCandidate>()
          .toList();
      expect(phones, hasLength(7));
      final full = phones.where((p) => p.automaticallySelected).toList();
      final optionalPhones = phones
          .where((p) => !p.automaticallySelected)
          .toList();
      final optional = optionalPhones.first;
      expect(full, hasLength(5));
      expect(full.every(overlay.selectedCandidates.contains), isTrue);
      expect(optionalPhones, hasLength(2));
      expect(optionalPhones.any(overlay.selectedCandidates.contains), isFalse);
      expect(
        overlay.candidates.any((c) => c.kind == CandidateKind.address),
        isTrue,
      );
      final managementNumber = _drawnNumberBounds(6, '管理番号:', '09000009999');
      expect(
        full.where((p) => p.region.toRect().overlaps(managementNumber)),
        hasLength(1),
      );
      expect(
        overlay.candidates.any(
          (c) =>
              c.kind == CandidateKind.address &&
              c.region.top > 740 &&
              c.region.bottom < 810 &&
              c.region.right > 330,
        ),
        isTrue,
      );
      final evidence = await _evidence();
      await File('${evidence.path}/synthetic-input.png').writeAsBytes(bytes);
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      final screenshot = await binding.takeScreenshot(
        'japanese-phone-auto-hidden',
      );
      await File('${evidence.path}/auto-hidden.png').writeAsBytes(screenshot);

      final first = full.first;
      await tapCandidate(tester, first);
      overlay = tester.widget<CandidateOverlay>(find.byType(CandidateOverlay));
      expect(overlay.selectedCandidates.contains(first), isFalse);
      await tapCandidate(tester, first);
      overlay = tester.widget<CandidateOverlay>(find.byType(CandidateOverlay));
      expect(overlay.selectedCandidates.contains(first), isTrue);
      await tapCandidate(tester, optional);
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .selectedCandidates
            .contains(optional),
        isTrue,
      );
      await editorAction(tester, '取り消す');
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .selectedCandidates
            .contains(optional),
        isFalse,
      );
      await editorAction(tester, '写真に保存');
      await _until(tester, () => saver.saved != null);
      final after = img.decodeJpg(saver.saved!.bytes)!;
      final before = img.decodePng(bytes)!;
      expect(after.width, before.width);
      expect(after.height, before.height);
      for (final candidate in full) {
        final box = candidate.region.toRect();
        final original = _darkPixels(before, box);
        expect(original, greaterThan(50));
        expect(_darkPixels(after, box), lessThan(original * .05));
      }
      // Ground truth comes from the rendered photo, independently of OCR boxes.
      // Catch partial digits that remain just outside an underestimated box.
      for (final (row, prefix, number) in [
        (0, '電話番号:', '090-0000-1234'),
        (1, 'TEL:', '03 0000 5678'),
        (2, '', '050 0000 4321'),
        (3, '携帯:', '＋８１ ９０ ００００ ９８７６'),
        (6, '管理番号:', '09000009999'),
      ]) {
        final rect = _drawnNumberBounds(row, prefix, number);
        expect(_darkPixels(before, rect), greaterThan(100));
        expect(
          _darkPixels(after, rect),
          lessThan(5),
          reason: 'entire number on row $row',
        );
      }
      final postalBox = const Rect.fromLTWH(200, 755, 450, 50);
      expect(_darkPixels(before, postalBox), greaterThan(100));
      expect(
        _darkPixels(after, postalBox),
        lessThan(_darkPixels(before, postalBox) * .05),
      );
      // Existing address dictionary matches can affect Japanese field LABELS.
      // Short optional numbers, the date and the name remain visible.
      for (final (row, left) in [
        (4, 140.0),
        (5, 140.0),
        (7, 140.0),
        (10, 40.0),
      ]) {
        final box = Rect.fromLTWH(left, 35 + row * 90, 650 - left, 50);
        final original = _darkPixels(before, box);
        expect(original, greaterThan(100));
        expect(
          _darkPixels(after, box),
          closeTo(original, original * .1),
          reason: 'unselected value on synthetic row $row',
        );
      }
      await File('${evidence.path}/synthetic-saved.jpg')
          .writeAsBytes(saver.saved!.bytes);
      await File('${evidence.path}/results.json').writeAsString(
        jsonEncode({
          'automatic_phone_candidates': full.length,
          'optional_phone_candidates': phones.length - full.length,
          'address_candidates': overlay.candidates
              .where((c) => c.kind == CandidateKind.address)
              .length,
          'gallery_save_succeeded': true,
          'dimensions': [after.width, after.height],
          'phone_pixels_removed': true,
          'entire_drawn_phone_pixels_removed': true,
          'postal_code_still_masked': true,
          'management_number_masked': true,
          'optional_date_name_values_preserved': true,
          'address_regions': [
            for (final c in overlay.candidates.where(
              (c) => c.kind == CandidateKind.address,
            ))
              [c.region.left, c.region.top, c.region.right, c.region.bottom],
          ],
        }),
      );
    },
  );
}

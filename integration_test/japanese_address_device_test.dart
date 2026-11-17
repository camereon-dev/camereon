import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'editor_support.dart';

class RecordingSaver implements PhotoSaver {
  RedactedJpeg? saved;
  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    final result = await AndroidPhotoSaver().save(jpeg);
    if (result is SaveSucceeded) saved = jpeg;
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Japanese OCR: only public addresses toggle and save', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    // Public government offices, not a private person's address.
    final rows = [
      '東京都新宿区西新宿2丁目8番1号',
      '大阪府大阪市北区中之島1丁目3番20号',
      '山田花子 様',
      '電話 03-0000-1234',
      'お届け先 ご案内',
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
      )..layout(maxWidth: 1100);
      painter.paint(canvas, Offset(40, 40 + i * 100));
      painter.dispose();
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(1200, 600);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final bytes = data!.buffer.asUint8List();
    final saver = RecordingSaver();
    await tester.pumpWidget(
      MaterialApp(
        home: CapturedPhotoScreen(photo: XFile.fromData(bytes), saver: saver),
      ),
    );
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (find.byType(CandidateOverlay).evaluate().isNotEmpty &&
          tester
              .widget<CandidateOverlay>(find.byType(CandidateOverlay))
              .candidates
              .isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    var overlay = tester.widget<CandidateOverlay>(
      find.byType(CandidateOverlay),
    );
    expect(overlay.candidates.length, greaterThanOrEqualTo(4));
    final count = overlay.candidates.length;
    expect(
      overlay.candidates.every((c) => c.kind == CandidateKind.address),
      isTrue,
    );
    expect(overlay.selectedCandidates, hasLength(count));
    final first = overlay.candidates.first;
    await tapCandidate(tester, first);
    overlay = tester.widget<CandidateOverlay>(find.byType(CandidateOverlay));
    expect(overlay.selectedCandidates, hasLength(count - 1));
    await tapCandidate(tester, first);
    expect(
      tester
          .widget<CandidateOverlay>(find.byType(CandidateOverlay))
          .selectedCandidates,
      hasLength(count),
    );
    await tapCandidate(tester, first);
    final hidden = tester
        .widget<CandidateOverlay>(find.byType(CandidateOverlay))
        .selectedCandidates
        .last;
    await editorAction(tester, '保存前に確認');
    // pumpAndSettle only waits for frames, not native image processing or IO.
    for (var i = 0; i < 150 && find.text('写真に保存').evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('写真に保存'), findsOneWidget);
    await editorAction(tester, '写真に保存');
    for (var i = 0; i < 150 && saver.saved == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(saver.saved, isNotNull);
    final output = img.decodeJpg(saver.saved!.bytes)!;
    final original = img.decodePng(bytes)!;
    double difference(Rect rect) {
      var sum = 0.0;
      var count = 0;
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          sum +=
              (output.getPixel(x, y).luminance -
                      original.getPixel(x, y).luminance)
                  .abs();
          count++;
        }
      }
      return sum / count;
    }

    expect(difference(hidden.region.toRect()), greaterThan(15));
    expect(difference(first.region.toRect()), lessThan(5));
    expect(difference(const Rect.fromLTWH(40, 240, 500, 40)), lessThan(5));
    expect(difference(const Rect.fromLTWH(40, 340, 500, 40)), lessThan(5));
  });
}

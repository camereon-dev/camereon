import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
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

import '../tools/text-region-eval/edge_density_detector.dart';
import 'editor_support.dart';

typedef Fixture = ({String name, SourcePhoto photo, List<Rect> expected});

class RecordingSaver implements PhotoSaver {
  RedactedJpeg? jpeg;
  @override
  Future<SaveResult> save(RedactedJpeg photo) async {
    final result = await AndroidPhotoSaver().save(photo);
    if (result is SaveSucceeded) jpeg = photo;
    return result;
  }
}

Future<List<Fixture>> fixtures() async {
  final data = await rootBundle.load('tools/vlm-eval/fixtures/parcel_ja.png');
  final original = img.decodePng(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  )!;
  const rects = [
    Rect.fromLTRB(80, 210, 192, 236),
    Rect.fromLTRB(80, 269, 232, 296),
    Rect.fromLTRB(80, 329, 427, 356),
    Rect.fromLTRB(80, 390, 310, 415),
  ];
  SourcePhoto source(img.Image image) => SourcePhoto(
    bytes: img.encodePng(image),
    width: image.width,
    height: image.height,
  );
  final lowContrast = img.adjustColor(original, contrast: .3);
  final random = math.Random(14);
  final texture = img.Image(width: 640, height: 640);
  img.fill(texture, color: img.ColorRgb8(235, 235, 235));
  for (var i = 0; i < 300; i++) {
    final x = random.nextInt(600);
    final y = random.nextInt(600);
    img.drawRect(
      texture,
      x1: x,
      y1: y,
      x2: x + random.nextInt(35) + 3,
      y2: y + random.nextInt(35) + 3,
      color: img.ColorRgb8(70, 70, 70),
    );
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
  final documentBounds = <Rect>[];
  for (var i = 0; i < 8; i++) {
    final text = TextPainter(
      text: TextSpan(
        text: '架空の書類 サンプル番号 ${i + 1}',
        style: const TextStyle(fontSize: 28, color: Colors.black),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = Offset(40, 40 + i * 65.0);
    text.paint(canvas, offset);
    documentBounds.add(offset & Size(text.width, text.height));
    text.dispose();
  }
  final picture = recorder.endRecording();
  final document = await picture.toImage(640, 640);
  final documentBytes = (await document.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  document.dispose();
  picture.dispose();
  return [
    (name: 'parcel', photo: source(original), expected: rects),
    (
      name: 'large_source',
      photo: source(img.copyResize(original, width: 1280, height: 1280)),
      expected: [
        for (final r in rects)
          Rect.fromLTRB(r.left * 2, r.top * 2, r.right * 2, r.bottom * 2),
      ],
    ),
    (
      name: 'rotated_90',
      photo: source(img.copyRotate(original, angle: 90)),
      expected: [
        for (final r in rects)
          Rect.fromLTRB(640 - r.bottom, r.left, 640 - r.top, r.right),
      ],
    ),
    (name: 'low_contrast', photo: source(lowContrast), expected: rects),
    (
      name: 'document',
      photo: SourcePhoto(
        bytes: documentBytes.buffer.asUint8List(),
        width: 640,
        height: 640,
      ),
      expected: documentBounds,
    ),
    (
      name: 'blank',
      photo: source(
        img.fill(
          img.Image(width: 640, height: 640),
          color: img.ColorRgb8(240, 240, 240),
        ),
      ),
      expected: [],
    ),
    (name: 'texture_no_text', photo: source(texture), expected: []),
  ];
}

double iou(Rect a, Rect b) {
  final r = a.intersect(b);
  final intersection = math.max(0.0, r.width) * math.max(0.0, r.height);
  return intersection /
      (a.width * a.height + b.width * b.height - intersection);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'compare detection-only and edge baseline on the same offline fixtures',
    (tester) async {
      final corpus = await fixtures();
      for (final (name, detector) in <(String, RegionDetector)>[
        ('paddle_detector', AndroidTextRegionDetector()),
        ('edge_density', EdgeDensityDetector()),
      ]) {
        final cases = <Map<String, Object>>[];
        for (final fixture in corpus) {
          final times = <double>[];
          late RegionDetection detection;
          for (var run = 0; run < 4; run++) {
            final timer = Stopwatch()..start();
            detection = await detector.detect(fixture.photo);
            timer.stop();
            times.add(timer.elapsedMicroseconds / 1000);
          }
          final unmatched = fixture.expected.toList();
          var tp = 0;
          for (final candidate in detection.candidates) {
            final r = candidate.region.toRect();
            unmatched.sort((a, b) => iou(r, b).compareTo(iou(r, a)));
            if (unmatched.isNotEmpty && iou(r, unmatched.first) >= .3) {
              tp++;
              unmatched.removeAt(0);
            }
          }
          final warm = times.skip(1).toList()..sort();
          cases.add({
            'image': fixture.name,
            'first_ms': times.first,
            'median_warm_ms': warm[1],
            'expected': fixture.expected.length,
            'predicted': detection.candidates.length,
            'tp': tp,
            'fp': detection.candidates.length - tp,
            'fn': unmatched.length,
            'boxes': detection.candidates
                .map(
                  (c) => [
                    c.region.left,
                    c.region.top,
                    c.region.right,
                    c.region.bottom,
                  ],
                )
                .toList(),
          });
          if (name == 'paddle_detector' &&
              (fixture.name == 'parcel' || fixture.name == 'large_source')) {
            expect(
              tp,
              4,
              reason: 'The bundled sample must offer all four text lines.',
            );
          }
          if (name == 'paddle_detector' && fixture.name == 'blank') {
            expect(detection.candidates, isEmpty);
          }
        }
        // No image bytes or recognized strings; fixtures contain fictional data only.
        // ignore: avoid_print
        print(
          'TEXT_REGION_EVAL ${jsonEncode({'method': name, 'iou_threshold': .3, 'cases': cases})}',
        );
      }
    },
  );

  testWidgets(
    'automatic native detection -> tap image frame -> JPEG gallery save',
    (tester) async {
      final data = await rootBundle.load(
        'tools/vlm-eval/fixtures/parcel_ja.png',
      );
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/CAP-text-regions.png');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final saver = RecordingSaver();
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(photo: XFile(file.path), saver: saver),
        ),
      );
      await tester.pumpAndSettle();
      final overlay = tester.widget<CandidateOverlay>(
        find.byType(CandidateOverlay),
      );
      final texts = overlay.candidates
          .where((c) => c.kind == CandidateKind.text)
          .toList();
      expect(texts.length, 4);
      // Only the image frames are interactive; keep the first line visible.
      for (final candidate in texts) {
        await tapCandidate(tester, candidate);
      }
      await tapCandidate(tester, texts.first);
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .selectedCandidates
            .length,
        3,
      );
      for (final label in ['保存前に確認', '写真に保存']) {
        await editorAction(tester, label);
      }
      expect(find.text('写真を保存しました'), findsOneWidget);
      final jpeg = saver.jpeg!;
      expect((jpeg.width, jpeg.height), (640, 640));
      final decoded = img.decodeJpg(jpeg.bytes)!;
      expect(decoded.getPixel(78, 205).luminance, greaterThan(240));
      for (final (x, y) in [(150, 282), (250, 343), (190, 403)]) {
        expect(decoded.getPixel(x, y).luminance, lessThan(4));
      }
      expect(decoded.exif.isEmpty, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await file.exists(), isFalse);
    },
  );
}

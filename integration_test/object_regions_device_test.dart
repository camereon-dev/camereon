import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:camereon/core/detection/android_object_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'editor_support.dart';

double iou(Rect a, Rect b) {
  final intersection = a.intersect(b);
  final area =
      math.max(0.0, intersection.width) * math.max(0.0, intersection.height);
  return area / (a.width * a.height + b.width * b.height - area);
}

Future<void> tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled detector returns no candidates for a blank image', (
    tester,
  ) async {
    final image = img.Image(width: 640, height: 480);
    img.fill(image, color: img.ColorRgb8(200, 200, 200));
    final source = SourcePhoto(
      bytes: img.encodePng(image),
      width: 640,
      height: 480,
    );
    expect(
      (await AndroidObjectRegionDetector().detect(source)).candidates,
      isEmpty,
    );
  });

  testWidgets(
    'private photos: actual Android model, source coordinates and editor save',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/detector-eval');
      final files = [
        for (var i = 1; i <= 3; i++) File('${directory.path}/photo-$i.png'),
      ];
      // Fixtures are pushed to this debug app after the test APK is installed.
      // Private originals are deliberately absent from pubspec and Git.
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (!files.every((file) => file.existsSync())) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Private fixtures not staged');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      });
      final detector = AndroidObjectRegionDetector();
      final measurements = <Map<String, Object>>[];
      late SourcePhoto last;
      try {
        for (var i = 0; i < files.length; i++) {
          final source = await FlutterPhotoProcessor().normalize(
            await files[i].readAsBytes(),
          );
          last = source;
          final watch = Stopwatch()..start();
          final result = await detector.detect(source);
          final people = result.candidates
              .where((c) => c.kind == CandidateKind.person)
              .toList();
          final screens = result.candidates
              .where((c) => c.kind == CandidateKind.screen)
              .toList();
          for (final candidate in result.candidates) {
            final r = candidate.region;
            expect(
              r.left >= 0 &&
                  r.top >= 0 &&
                  r.right <= source.width &&
                  r.bottom <= source.height,
              isTrue,
            );
          }
          if (i == 0) {
            expect(people.length, greaterThanOrEqualTo(2));
            expect(
              screens.any(
                (c) =>
                    iou(
                      c.region.toRect(),
                      const Rect.fromLTRB(521, 237, 661, 467),
                    ) >
                    .5,
              ),
              isTrue,
            );
          } else if (i == 1) {
            expect(screens.length, greaterThanOrEqualTo(3));
          } else {
            expect(
              screens.any(
                (c) =>
                    iou(
                      c.region.toRect(),
                      const Rect.fromLTRB(811, 427, 1017, 545),
                    ) >
                    .5,
              ),
              isTrue,
            );
          }
          measurements.add({
            'photo': i + 1,
            'wallMs': watch.elapsedMilliseconds,
            'width': source.width,
            'height': source.height,
            'people': people.length,
            'screens': screens.length,
          });
        }
        // Exercise the normal editor -> actual native inference -> selection ->
        // JPEG -> MediaStore path with the third private photo.
        final temp = File('${support.path}/detector-editor.png');
        await temp.writeAsBytes(last.bytes);
        await tester.pumpWidget(
          MaterialApp(home: CapturedPhotoScreen(photo: XFile(temp.path))),
        );
        await tester.pumpAndSettle();
        final screen = tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .candidates
            .firstWhere((c) => c.kind == CandidateKind.screen);
        await tapCandidate(tester, screen);
        await editorAction(tester, '保存前に確認');
        await tap(tester, '写真に保存');
        expect(find.text('写真を保存しました'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(await temp.exists(), isFalse);
        await File('${directory.path}/results.json')
            .writeAsString(jsonEncode(measurements));
      } finally {
        for (final file in files) {
          if (await file.exists()) await file.delete();
        }
      }
    },
    skip: !const bool.fromEnvironment('RUN_PRIVATE_DETECTOR_TESTS'),
  );
}

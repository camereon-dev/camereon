import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/analysis/infrastructure/mlkit_face_detector.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/image_photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'editor_support.dart';

class ObservedDetector implements PhotoFaceDetector {
  final completed = Completer<List<FaceCandidate>>();
  SourcePhoto? photo;
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) async {
    photo = source;
    try {
      final faces = await MlKitFaceDetector().detect(source);
      completed.complete(faces);
      return faces;
    } catch (error, stack) {
      completed.completeError(error, stack);
      rethrow;
    }
  }
}

class ObservedSaver implements PhotoSaver {
  RedactedJpeg? saved;
  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    final result = await AndroidPhotoSaver().save(jpeg);
    if (result is SaveSucceeded) saved = jpeg;
    return result;
  }
}

Future<Set<String>> galleryFiles(Directory directory) async =>
    await directory.exists()
    ? (await directory.list().toList())
          .whereType<File>()
          .map((f) => f.path)
          .toSet()
    : <String>{};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'offline first UI detection, individual edit, MediaStore readback and fixtures',
    (tester) async {
      const fixture = String.fromEnvironment('FACE_FIXTURE_BASE64');
      expect(
        fixture,
        isNotEmpty,
        reason: 'Supply FACE_FIXTURE_BASE64. No blank-only pass.',
      );
      final bytes = base64Decode(fixture);
      final support = await getApplicationSupportDirectory();
      expect(
        await support
            .list(recursive: true)
            .any((f) => f.path.endsWith('.litertlm')),
        isFalse,
        reason: 'Run with clean app data and no Gemma model.',
      );
      final report = <String, Object?>{};
      final observed = ObservedDetector();
      final saver = ObservedSaver();
      // No earlier detector call: the first ML Kit invocation comes from the editor.
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(bytes),
            faceDetector: observed,
            saver: saver,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final faces = await observed.completed.future.timeout(
        const Duration(seconds: 30),
      );
      await tester.pumpAndSettle();
      expect(faces.length, 1);
      await tester.ensureVisible(find.text('顔だけ'));
      await tester.tap(find.text('顔だけ'));
      await tester.pumpAndSettle();
      expect(find.byType(FilterChip), findsNothing);
      final imageRect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
      final center = faces.single.region.toRect().center;
      final tap =
          imageRect.topLeft +
          Offset(
            center.dx / observed.photo!.width * imageRect.width,
            center.dy / observed.photo!.height * imageRect.height,
          );
      await tester.tapAt(tap);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .selectedCandidates
            .length,
        1,
      );
      await tester.tapAt(tap);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .selectedCandidates,
        isEmpty,
      );
      await editorAction(tester, '取り消す');
      // This path is intentionally Android emulator-specific. Only the newly
      // created, app-owned MediaStore image is read; existing photos are untouched.
      final gallery = Directory(
        const String.fromEnvironment(
          'FACE_GALLERY_DIRECTORY',
          defaultValue: '/storage/emulated/0/Pictures/camereon',
        ),
      );
      final before = await galleryFiles(gallery);
      await editorAction(tester, '保存前に確認');
      await tester.ensureVisible(find.text('写真に保存'));
      await tester.tap(find.text('写真に保存'));
      await tester.pumpAndSettle();
      expect(find.text('写真を保存しました'), findsOneWidget);
      final created = (await galleryFiles(gallery)).difference(before);
      expect(created.length, 1);
      final persisted = await File(created.single).readAsBytes();
      expect(sha256.convert(persisted), sha256.convert(saver.saved!.bytes));
      final savedPixels = img.decodeJpg(persisted)!;
      expect(
        (savedPixels.width, savedPixels.height),
        (saver.saved!.width, saver.saved!.height),
      );
      expect(savedPixels.exif.isEmpty, isTrue);
      final r = faces.single.region;
      // Check the entire interior, not only a single central pixel. JPEG edges
      // may contain codec ringing; allow a two-pixel inset and channel value <5.
      for (var y = r.top + 2; y < r.bottom - 2; y++) {
        for (var x = r.left + 2; x < r.right - 2; x++) {
          final p = savedPixels.getPixel(x, y);
          expect(p.r, lessThan(5));
          expect(p.g, lessThan(5));
          expect(p.b, lessThan(5));
        }
      }
      expect(savedPixels.getPixel(0, 0).luminance, greaterThan(10));
      report['firstUiDetection'] = true;
      report['faceOnlyFrameTapAndUndo'] = true;
      report['galleryReadback'] = {
        'sha256': sha256.convert(persisted).toString(),
        'width': savedPixels.width,
        'height': savedPixels.height,
        'region': [r.left, r.top, r.right, r.bottom],
      };
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      final processor = FlutterPhotoProcessor();
      final detector = MlKitFaceDetector();
      final upright = img.decodeImage(bytes)!;
      final cases = <String, img.Image>{
        'frontal': upright,
        'no_face': img.Image(width: 640, height: 480),
      };
      // A synthetic smaller-face scene: same portrait reduced and placed on a
      // larger canvas. This is not evidence from a naturally distant subject.
      for (final height in [256, 128]) {
        final canvas = img.Image(width: 1600, height: 1200);
        img.fill(canvas, color: img.ColorRgb8(180, 180, 180));
        final small = img.copyResize(upright, height: height);
        img.compositeImage(canvas, small, dstX: 600, dstY: 400);
        cases['small_portrait_$height'] = canvas;
      }
      const group = String.fromEnvironment('FACE_GROUP_BASE64');
      const oblique = String.fromEnvironment('FACE_OBLIQUE_BASE64');
      if (group.isNotEmpty) {
        cases['two_people'] = img.decodeImage(base64Decode(group))!;
        cases['two_people_resized'] = img.copyResize(
          cases['two_people']!,
          width: 640,
        );
      }
      if (oblique.isNotEmpty) {
        cases['oblique_not_full_profile'] = img.decodeImage(
          base64Decode(oblique),
        )!;
      }
      final results = <String, Object?>{};
      for (final entry in cases.entries) {
        final source = await processor.normalize(img.encodePng(entry.value));
        final found = await detector.detect(source);
        results[entry.key] = {
          'width': source.width,
          'height': source.height,
          'expectedVisibleFaces': entry.key == 'no_face'
              ? 0
              : entry.key.startsWith('two_people')
              ? 2
              : 1,
          'count': found.length,
          'regions': [
            for (final f in found)
              [f.region.left, f.region.top, f.region.right, f.region.bottom],
          ],
        };
        if (entry.key == 'frontal') expect(found.length, 1);
        if (entry.key == 'no_face') expect(found, isEmpty);
        // Accuracy evaluation: preserve expected and measured counts, including
        // misses. A passing transport/UI test is not an accuracy acceptance.
        debugPrint('FACE_CASE ${entry.key} ${jsonEncode(results[entry.key])}');
      }
      final rotated = img.copyRotate(upright, angle: -90);
      rotated.exif.imageIfd.orientation = 6;
      final normalized = await ImagePhotoProcessor().normalize(
        img.encodeJpg(rotated),
      );
      final orientedFaces = await detector.detect(normalized);
      expect(orientedFaces.length, 1);
      expect(
        (normalized.width, normalized.height),
        (upright.width, upright.height),
      );
      final o = orientedFaces.single.region;
      for (final pair in [
        (o.left, r.left),
        (o.top, r.top),
        (o.right, r.right),
        (o.bottom, r.bottom),
      ]) {
        expect(pair.$1, closeTo(pair.$2, 30));
      }
      report['fixtures'] = results;
      report['normalizedExifRotation'] = true;
      await File('${support.path}/face-evaluation.json')
          .writeAsString(jsonEncode(report));
      // Only explicit evaluation fixtures; never add this to production logging.
      debugPrint('FACE_EVALUATION ${jsonEncode(report)}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

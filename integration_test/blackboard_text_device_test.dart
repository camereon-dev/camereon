import 'dart:convert';
import 'dart:io';

import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'public blackboards: native detection and redaction output for visual acceptance',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/blackboard-eval');
      final manifest = File('${dir.path}/sources.json');
      await tester.runAsync(() async {
        final end = DateTime.now().add(const Duration(minutes: 3));
        while (!await manifest.exists()) {
          if (DateTime.now().isAfter(end)) {
            throw StateError(
              'Stage public fixtures after test APK installation',
            );
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      });
      final sources = (jsonDecode(await manifest.readAsString()) as List)
          .cast<Map<String, dynamic>>();
      final report = <Map<String, Object>>[];
      final processor = FlutterPhotoProcessor();
      for (final item in sources) {
        final id = item['id'] as String;
        expect(RegExp(r'^[a-z-]+$').hasMatch(id), isTrue);
        final input = await File('${dir.path}/$id.jpg').readAsBytes();
        expect(sha256.convert(input).toString(), item['sha256']);
        final source = await processor.normalize(input);
        final runs = <String, Object>{};
        for (final mode in [
          (name: 'baseline', detailed: false, ocr: false),
          (name: 'geometry', detailed: true, ocr: false),
          (name: 'detail', detailed: true, ocr: true),
        ]) {
          final timer = Stopwatch()..start();
          final result = await AndroidTextRegionDetector(
            detailed: mode.detailed,
            supplementalOcr: mode.ocr,
          ).detect(source);
          expect(result.partial, isFalse, reason: '${mode.name}: $id');
          runs[mode.name] = {
            'wall_ms': timer.elapsedMilliseconds,
            'truncated': result.truncated,
            'partial': result.partial,
            'boxes': [
              for (final c in result.candidates)
                [c.region.left, c.region.top, c.region.right, c.region.bottom],
            ],
          };
          if (mode.name == 'detail') {
            final jpeg = await processor.redact(source, [
              for (final c in result.candidates) c.region,
            ]);
            final pixels = img.decodeJpg(jpeg.bytes)!;
            expect(
              (pixels.width, pixels.height),
              (source.width, source.height),
            );
            expect(pixels.exif.isEmpty, isTrue);
            for (final c in result.candidates) {
              expect(
                pixels
                    .getPixel(
                      (c.region.left + c.region.right) ~/ 2,
                      (c.region.top + c.region.bottom) ~/ 2,
                    )
                    .luminance,
                lessThan(6),
              );
            }
            await File('${dir.path}/$id-masked.jpg').writeAsBytes(jpeg.bytes);
            if (id == 'japanese-menu') {
              expect(
                await AndroidPhotoSaver().save(jpeg),
                isA<SaveSucceeded>(),
              );
            }
          }
        }
        report.add({
          'id': id,
          'width': source.width,
          'height': source.height,
          'runs': runs,
        });
        // Public file ID/counts only; there is no OCR string output.
        // ignore: avoid_print
        print(
          'BLACKBOARD_CASE ${jsonEncode({
            'id': id,
            'counts': {for (final e in runs.entries) e.key: ((e.value as Map)['boxes'] as List).length},
          })}',
        );
      }
      await File('${dir.path}/results.json').writeAsString(jsonEncode(report));
      // Exporting candidate boxes is not a text-accuracy acceptance test.
      // Visual acceptance is recorded separately, including every selected image.
      // ignore: avoid_print
      print('BLACKBOARD_READY');
      await tester.runAsync(() async {
        final end = DateTime.now().add(const Duration(seconds: 60));
        while (!await File('${dir.path}/collected').exists()) {
          if (DateTime.now().isAfter(end)) {
            throw StateError('Collect evaluation outputs and acknowledge');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });
    },
    skip: !const bool.fromEnvironment('RUN_BLACKBOARD_TEXT_TESTS'),
  );
}

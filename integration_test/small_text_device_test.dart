import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

typedef Fixture = ({String name, SourcePhoto photo, List<Rect> expected});

Future<Fixture> smallText({
  double scale = 1,
  bool blank = false,
  double fontSize = 6,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(Colors.white, BlendMode.src)
    ..scale(scale);
  final expected = <Rect>[];
  if (!blank) {
    for (final y in [150.0, 430.0, 800.0, 1190.0]) {
      // Several rows cross crop boundaries. All strings are fictional fixtures.
      for (final x in [160.0, 590.0, 1100.0, 1650.0, 2200.0]) {
        final text = TextPainter(
          text: TextSpan(
            text: '架空サンプル12345',
            style: TextStyle(
              fontFamily: 'SmallTextFixture',
              fontSize: fontSize,
              color: Colors.black,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, Offset(x, y));
        expected.add(
          Rect.fromLTWH(
            x * scale,
            y * scale,
            text.width * scale,
            text.height * scale,
          ),
        );
        text.dispose();
      }
    }
  }
  final width = (2560 * scale).round();
  final height = (1440 * scale).round();
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return (
      name: blank ? 'blank_$width' : 'font${fontSize.toInt()}_$width',
      photo: SourcePhoto(
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: width,
        height: height,
      ),
      expected: expected,
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

double iou(Rect a, Rect b) {
  final r = a.intersect(b);
  final intersection = math.max(0.0, r.width) * math.max(0.0, r.height);
  return intersection /
      (a.width * a.height + b.width * b.height - intersection);
}

Map<String, int> match(RegionDetection result, List<Rect> expected) {
  final remaining = expected.toList();
  var tp = 0;
  for (final candidate in result.candidates) {
    remaining.sort(
      (a, b) => iou(
        candidate.region.toRect(),
        b,
      ).compareTo(iou(candidate.region.toRect(), a)),
    );
    if (remaining.isNotEmpty &&
        iou(candidate.region.toRect(), remaining.first) >= .3) {
      tp++;
      remaining.removeAt(0);
    }
  }
  return {
    'tp': tp,
    'fp': result.candidates.length - tp,
    'fn': remaining.length,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'small text: native baseline/detail recall, seams, blank and source coordinates',
    (tester) async {
      // Flutter test fonts can replace glyphs with rectangles. Load the actual
      // Android Japanese font so this measures tiny characters, not solid blocks.
      final fontFile = File(
        const String.fromEnvironment(
          'SMALL_TEXT_FONT_PATH',
          defaultValue: '/system/fonts/NotoSansCJK-Regular.ttc',
        ),
      );
      final fontBytes = await fontFile.readAsBytes();
      await (FontLoader(
        'SmallTextFixture',
      )..addFont(Future.value(ByteData.sublistView(fontBytes)))).load();
      final report = <Map<String, Object>>[];
      for (final fixture in [
        await smallText(),
        await smallText(scale: 1.5),
        await smallText(fontSize: 8),
        await smallText(fontSize: 14),
        await smallText(blank: true),
      ]) {
        final runs = <String, Object>{};
        final counts = <bool, Map<String, int>>{};
        for (final detailed in [false, true]) {
          final watch = Stopwatch()..start();
          final result = await AndroidTextRegionDetector(detailed: detailed)
              .detect(fixture.photo);
          final metrics = match(result, fixture.expected);
          counts[detailed] = metrics;
          for (final candidate in result.candidates) {
            expect(candidate.region.left, greaterThanOrEqualTo(0));
            expect(candidate.region.top, greaterThanOrEqualTo(0));
            expect(
              candidate.region.right,
              lessThanOrEqualTo(fixture.photo.width),
            );
            expect(
              candidate.region.bottom,
              lessThanOrEqualTo(fixture.photo.height),
            );
          }
          runs[detailed ? 'detail' : 'baseline'] = {
            ...metrics,
            'predicted': result.candidates.length,
            'wall_ms': watch.elapsedMilliseconds,
            'truncated': result.truncated,
          };
          // ignore: avoid_print
          print(
            'SMALL_TEXT_CASE ${jsonEncode({'fixture': fixture.name, 'detailed': detailed, ...metrics, 'predicted': result.candidates.length, 'wall_ms': watch.elapsedMilliseconds})}',
          );
          if (fixture.expected.isEmpty) expect(result.candidates, isEmpty);
          if (detailed && fixture.expected.isNotEmpty) {
            expect(
              metrics['tp'],
              greaterThanOrEqualTo(18),
              reason: fixture.name,
            );
            expect(metrics['fp'], lessThanOrEqualTo(2), reason: fixture.name);
            if (fixture.name.startsWith('font6')) {
              expect(
                metrics['tp'],
                greaterThan(counts[false]!['tp']!),
                reason: 'Must improve small-text recall',
              );
            } else {
              expect(
                metrics['tp'],
                greaterThanOrEqualTo(counts[false]!['tp']!),
                reason: 'Retain ordinary text recall',
              );
            }
          }
        }
        report.add({
          'fixture': fixture.name,
          'expected': fixture.expected.length,
          'runs': runs,
        });
      }
      // Check that multi-crop deduplication retains one frame per existing line.
      final data = await rootBundle.load(
        'tools/vlm-eval/fixtures/parcel_ja.png',
      );
      final source = await FlutterPhotoProcessor().normalize(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final codec = await ui.instantiateImageCodec(
        source.bytes,
        targetWidth: 1280,
        targetHeight: 1280,
      );
      final frame = await codec.getNextFrame();
      final png = (await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      try {
        final result = await AndroidTextRegionDetector().detect(
          SourcePhoto(
            bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            width: 1280,
            height: 1280,
          ),
        );
        expect(
          result.candidates.length,
          4,
          reason: 'Overlapping crops must not duplicate the four label lines',
        );
      } finally {
        frame.image.dispose();
        codec.dispose();
      }
      // No recognized strings or image bytes are logged.
      // ignore: avoid_print
      print('SMALL_TEXT_EVAL ${jsonEncode(report)}');
    },
  );

  testWidgets(
    'private photos: native text comparison on the same oriented pixels',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/detector-eval');
      final files = [
        for (var i = 1; i <= 3; i++) File('${directory.path}/photo-$i.png'),
      ];
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (!files.every((file) => file.existsSync())) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Private fixtures not staged');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      });
      final report = <Map<String, Object>>[];
      try {
        for (var i = 0; i < files.length; i++) {
          final source = await FlutterPhotoProcessor().normalize(
            await files[i].readAsBytes(),
          );
          final runs = <String, Object>{};
          for (final detailed in [false, true]) {
            final watch = Stopwatch()..start();
            final result = await AndroidTextRegionDetector(detailed: detailed)
                .detect(source);
            runs[detailed ? 'detail' : 'baseline'] = {
              'wall_ms': watch.elapsedMilliseconds,
              'count': result.candidates.length,
              'truncated': result.truncated,
              'boxes': [
                for (final c in result.candidates)
                  [
                    c.region.left,
                    c.region.top,
                    c.region.right,
                    c.region.bottom,
                  ],
              ],
            };
          }
          report.add({'photo': i + 1, 'runs': runs});
        }
        await File('${directory.path}/small-text-results.json')
            .writeAsString(jsonEncode(report));
        // ignore: avoid_print
        print(
          'PRIVATE_SMALL_TEXT_EVAL ${jsonEncode([
            for (final record in report) {
                'photo': record['photo'],
                'runs': {
                  for (final entry in (record['runs'] as Map<String, Object>).entries) entry.key: {for (final field in (entry.value as Map<String, Object>).entries)
                      if (field.key != 'boxes') field.key: field.value},
                },
              },
          ])}',
        );
      } finally {
        for (final file in files) {
          if (await file.exists()) await file.delete();
        }
      }
    },
    skip: !const bool.fromEnvironment('RUN_PRIVATE_SMALL_TEXT_TESTS'),
  );
}

import 'dart:io';

import 'package:camereon/core/analysis/infrastructure/mlkit_face_detector.dart';
import 'package:camereon/core/detection/android_object_region_detector.dart';
import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'text_regions_device_test.dart' as corpus;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iPhone: bundled text, object and face engines run offline', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('端末内の自動検出を検証中'))),
      ),
    );
    final text = AndroidTextRegionDetector();
    final fixtures = await corpus.fixtures();
    for (final fixture in fixtures.where(
      (f) => ['parcel', 'large_source', 'rotated_90', 'blank'].contains(f.name),
    )) {
      final watch = Stopwatch()..start();
      final result = await text.detect(fixture.photo);
      expect(result.partial, isFalse);
      expect(result.truncated, isFalse);
      for (final expected in fixture.expected) {
        expect(
          result.candidates.any(
            (c) => corpus.iou(c.region.toRect(), expected) >= .3,
          ),
          isTrue,
          reason: '${fixture.name}: missed $expected',
        );
      }
      if (fixture.name == 'blank') expect(result.candidates, isEmpty);
      // Only synthetic-image metrics are logged; no input pixels or text contents.
      debugPrint(
        'iOS text ${fixture.name}: ${result.candidates.length} candidates, ${watch.elapsedMilliseconds} ms',
      );
    }
    final blank = fixtures.firstWhere((f) => f.name == 'blank').photo;
    expect(
      (await AndroidObjectRegionDetector().detect(blank)).candidates,
      isEmpty,
    );
    expect(await MlKitFaceDetector().detect(blank), isEmpty);
    await const MethodChannel('dev.camereon/text_regions')
        .invokeMethod<void>('release');
    final sample = await FlutterPhotoProcessor().normalize(
      fixtures.first.photo.bytes,
    );
    expect(
      (await text.detect(sample)).candidates,
      isNotEmpty,
      reason: 'Sessions must rebuild after memory release.',
    );
    await expectLater(
      const MethodChannel('dev.camereon/object_regions').invokeMethod<void>(
        'detect',
        {'bytes': Uint8List(4), 'width': 100, 'height': 100},
      ),
      throwsA(isA<PlatformException>()),
    );
  });
}

import 'package:camereon/core/detection/android_object_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/object_regions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final photo = SourcePhoto(
    bytes: img.encodePng(img.Image(width: 200, height: 100)),
    width: 200,
    height: 100,
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native regions retain their kind and map outward to the original image',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'width': 100,
          'height': 50,
          'truncated': false,
          'candidates': [
            {
              'kind': 'person',
              'box': [5.1, 3.1, 40.1, 30.1],
            },
            {
              'kind': 'screen',
              'box': [60, 10, 90, 40],
            },
          ],
        },
      );
      final result = await AndroidObjectRegionDetector(channel: channel)
          .detect(photo);
      expect(result.candidates.map((c) => c.kind), [
        CandidateKind.person,
        CandidateKind.screen,
      ]);
      final region = result.candidates.first.region;
      expect(
        [region.left, region.top, region.right, region.bottom],
        [10, 6, 81, 61],
      );
    },
  );

  test(
    'malformed or out-of-bounds native results fail and allow retry',
    () async {
      final detector = AndroidObjectRegionDetector(channel: channel);
      for (final value in [
        {
          'kind': 'unknown',
          'box': [1, 1, 50, 40],
        },
        {
          'kind': 'person',
          'box': [-1, 1, 50, 40],
        },
        {
          'kind': 'screen',
          'box': [1, 1, 101, 40],
        },
        {
          'kind': 'person',
          'box': [double.nan, 1, 50, 40],
        },
        {
          'kind': 'screen',
          'box': [1, 1, 0, 40],
        },
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {
            'width': 100,
            'height': 50,
            'truncated': false,
            'candidates': [value],
          },
        );
        await expectLater(
          detector.detect(photo),
          throwsA(isA<RegionDetectionException>()),
        );
      }
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'width': 100,
          'height': 50,
          'truncated': false,
          'candidates': [],
        },
      );
      expect((await detector.detect(photo)).candidates, isEmpty);
    },
  );
}

import 'package:camereon/core/detection/android_object_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
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
            {
              'kind': 'vehicle',
              'box': [0, 40, 50, 50],
            },
          ],
        },
      );
      final result = await AndroidObjectRegionDetector(channel: channel)
          .detect(photo);
      expect(result.candidates.map((c) => c.kind), [
        CandidateKind.person,
        CandidateKind.screen,
        CandidateKind.vehicle,
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

  test(
    'a silhouette mask is traced into a polygon inside its rectangle',
    () async {
      // 8x8 crop: a filled disc; cells outside the disc stay 0.
      final mask = Uint8List(64);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final dx = x - 3.5, dy = y - 3.5;
          if (dx * dx + dy * dy <= 10) mask[y * 8 + x] = 255;
        }
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'width': 100,
          'height': 50,
          'truncated': false,
          'candidates': [
            {
              'kind': 'person',
              'box': [10, 10, 40, 40],
              'mask': {
                'width': 8,
                'height': 8,
                'bytes': mask,
                'left': 10,
                'top': 10,
                'right': 42,
                'bottom': 42,
              },
            },
            {
              'kind': 'vehicle',
              'box': [50, 10, 90, 40],
              'mask': {
                'width': 4,
                'height': 4,
                'bytes': Uint8List(16),
                'left': 50,
                'top': 10,
                'right': 90,
                'bottom': 40,
              },
            },
          ],
        },
      );
      final result = await AndroidObjectRegionDetector(channel: channel)
          .detect(photo);
      final person = result.candidates.first.region;
      expect(person.shape, HideShape.polygon);
      // The disc fills the crop's centre and stays within the mask rectangle.
      expect(person.contains(const Offset(52, 52)), isTrue);
      expect(person.contains(const Offset(22, 22)), isFalse);
      expect(person.left, greaterThanOrEqualTo(20));
      expect(person.right, lessThanOrEqualTo(84));
      // An empty mask falls back to the rectangle.
      expect(result.candidates.last.region.shape, HideShape.rectangle);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'width': 100,
          'height': 50,
          'truncated': false,
          'candidates': [
            {
              'kind': 'person',
              'box': [10, 10, 40, 40],
              'mask': {'width': 8, 'height': 8, 'bytes': Uint8List(10)},
            },
          ],
        },
      );
      await expectLater(
        AndroidObjectRegionDetector(channel: channel).detect(photo),
        throwsA(isA<RegionDetectionException>()),
      );
    },
  );
}

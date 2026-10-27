import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/text_regions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final photo = SourcePhoto(
    bytes: img.encodePng(img.Image(width: 400, height: 200)),
    width: 400,
    height: 200,
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'maps thumbnail rectangles outward to source coordinates and deduplicates',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'detect');
        expect((call.arguments as Map).keys, ['bytes']);
        return {
          'width': 200,
          'height': 100,
          'boxes': [
            [10.2, 20.2, 80.1, 50.1],
            [10.2, 20.2, 80.1, 50.1],
          ],
          'truncated': true,
        };
      });
      final result = await AndroidTextRegionDetector(channel: channel)
          .detect(photo);
      expect(result.candidates.single.kind, CandidateKind.text);
      expect(
        result.candidates.single.region,
        HideRegion.fromRect(
          const Rect.fromLTRB(20.4, 40.4, 160.2, 100.2),
          imageWidth: 400,
          imageHeight: 200,
        ),
      );
      expect(result.truncated, isTrue);
    },
  );

  test('invalid responses fail, then retry succeeds; empty means a successful scan', () async {
    final detector = AndroidTextRegionDetector(channel: channel);
    for (final response in [
      null,
      {'width': 0, 'height': 100, 'boxes': []},
      {
        'width': 200,
        'height': 100,
        'boxes': [
          [1, 2, 1, 9],
        ],
      },
      {
        'width': 200,
        'height': 100,
        'boxes': [
          [double.nan, 2, 10, 9],
        ],
      },
      {
        'width': 200,
        'height': 100,
        'boxes': [
          ['text', 2, 10, 9],
        ],
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      await expectLater(
        detector.detect(photo),
        throwsA(isA<RegionDetectionException>()),
      );
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'width': 400, 'height': 200, 'boxes': []},
    );
    expect((await detector.detect(photo)).candidates, isEmpty);
  });
}

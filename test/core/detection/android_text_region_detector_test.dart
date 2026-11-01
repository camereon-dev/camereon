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
        expect((call.arguments as Map).keys, [
          'bytes',
          'detailed',
          'supplementalOcr',
        ]);
        expect((call.arguments as Map)['detailed'], isTrue);
        expect((call.arguments as Map)['supplementalOcr'], isTrue);
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

  test(
    'OCR failure retains primary regions and reports partial detection',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'width': 400,
          'height': 200,
          'boxes': [
            [10, 20, 80, 50],
          ],
          'partial': true,
        },
      );
      final result = await AndroidTextRegionDetector(channel: channel)
          .detect(photo);
      expect(result.candidates, hasLength(1));
      expect(result.partial, isTrue);
      expect(result.truncated, isFalse);
    },
  );

  test('can compare the detector without the OCR supplement', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect((call.arguments as Map)['detailed'], isTrue);
      expect((call.arguments as Map)['supplementalOcr'], isFalse);
      return {'width': 400, 'height': 200, 'boxes': []};
    });
    await AndroidTextRegionDetector(
      channel: channel,
      supplementalOcr: false,
    ).detect(photo);
  });

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
  for (final detailed in [false, true]) {
    test(
      'bounds transfer and restores high-resolution coordinates: detailed=$detailed',
      () async {
        final source = SourcePhoto(
          bytes: img.encodePng(img.Image(width: 4000, height: 1000)),
          width: 4000,
          height: 1000,
        );
        final maxSide = detailed ? 2560 : 960;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          expect(args['detailed'], detailed);
          expect(args['supplementalOcr'], detailed);
          final input = img.decodePng(args['bytes'])!;
          expect((input.width, input.height), (maxSide, maxSide ~/ 4));
          return {
            'width': input.width,
            'height': input.height,
            'boxes': [
              [10.1, 10.1, 30.1, 30.1],
            ],
            'truncated': false,
          };
        });
        final result = await AndroidTextRegionDetector(
          channel: channel,
          detailed: detailed,
        ).detect(source);
        final factor = 4000 / maxSide;
        expect(
          result.candidates.single.region,
          HideRegion.fromRect(
            Rect.fromLTRB(
              10.1 * factor,
              10.1 * factor,
              30.1 * factor,
              30.1 * factor,
            ),
            imageWidth: 4000,
            imageHeight: 1000,
          ),
        );
      },
    );
  }

  test('accepts 500 detail candidates and rejects oversized/malformed native replies', () async {
    final detector = AndroidTextRegionDetector(channel: channel);
    final boxes = [
      for (var i = 0; i < 500; i++)
        [i % 100, i ~/ 100, i % 100 + 1, i ~/ 100 + 1],
    ];
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'width': 400,
        'height': 200,
        'boxes': boxes,
        'truncated': true,
      },
    );
    expect((await detector.detect(photo)).candidates.length, 500);
    for (final response in [
      {'width': 2561, 'height': 200, 'boxes': []},
      {
        'width': 400,
        'height': 200,
        'boxes': [
          ...boxes,
          [300, 10, 301, 11],
        ],
      },
      {
        'width': 400,
        'height': 200,
        'boxes': [
          [-1, 0, 10, 10],
        ],
      },
      {
        'width': 400,
        'height': 200,
        'boxes': [
          [0, 0, 401, 10],
        ],
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      await expectLater(
        detector.detect(photo),
        throwsA(isA<RegionDetectionException>()),
      );
    }
  });
}

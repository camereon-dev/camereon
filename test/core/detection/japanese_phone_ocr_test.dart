import 'package:camereon/core/detection/japanese_address_detector.dart';
import 'package:camereon/core/detection/japanese_phone_number_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/combined-japanese-ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'one OCR response supplies address, postal and phone candidates',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'detect');
        return {
          'lines': [
            for (final (row, text) in [
              '東京都',
              '〒100-0001',
              'TEL:03-0000-1234',
              'TEL:12345678',
              '管理番号:09000009999',
              'TEL:123-4567',
            ].indexed)
              [
                for (var i = 0; i < text.length; i++)
                  {
                    'text': text[i],
                    'box': [
                      10 + i * 10,
                      10 + row * 30,
                      20 + i * 10,
                      26 + row * 30,
                    ],
                  },
              ],
          ],
        };
      });
      final photo = SourcePhoto(
        bytes: img.encodePng(img.Image(width: 400, height: 200)),
        width: 400,
        height: 200,
      );
      final result = await JapaneseAddressDetector(channel: channel)
          .detect(photo);
      expect(calls, 1);
      expect(
        result.candidates.where((c) => c.kind == CandidateKind.address),
        hasLength(greaterThanOrEqualTo(2)),
      );
      final phones = result.candidates
          .whereType<PhoneNumberCandidate>()
          .toList();
      expect(phones, hasLength(3));
      expect(phones.map((p) => p.automaticallySelected), [true, false, false]);
      expect(
        result.candidates
            .where((c) => c.kind == CandidateKind.address)
            .any((c) => c.region.top >= 155),
        isFalse,
      );
      expect(phones.first.region.top, 67);
      expect(phones.first.region.left, 47);
    },
  );
}

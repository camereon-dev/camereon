import 'package:camereon/core/photo/ios_photo_saver.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/ios_photo_saver');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final jpeg = RedactedJpeg(
    bytes: Uint8List.fromList([1, 2, 3, 4, 5]),
    width: 1,
    height: 1,
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('passes processed image bytes to the iOS Photos channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'save');
      expect(call.arguments, {'bytes': jpeg.bytes});
      return 'saved';
    });

    final result = await IosPhotoSaver(channel: channel).save(jpeg);

    expect(result, isA<SaveSucceeded>());
  });

  test(
    'preserves the permission-denied result for settings guidance',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => 'permissionDenied',
      );

      final result = await IosPhotoSaver(channel: channel).save(jpeg);

      expect(result, isA<SaveFailed>());
      expect((result as SaveFailed).reason, SaveFailureReason.permissionDenied);
    },
  );
}

import 'dart:typed_data';

import 'package:camereon/core/photo/android_photo_saver.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/photo_saver');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final jpeg = RedactedJpeg(
    bytes: Uint8List.fromList([1, 2, 3]),
    width: 1,
    height: 1,
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('sends only the processed JPEG bytes and reports success', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'save');
      expect(call.arguments, {'bytes': jpeg.bytes});
      return 'saved';
    });

    final result = await AndroidPhotoSaver(channel: channel).save(jpeg);

    expect(result, isA<SaveSucceeded>());
  });

  test('reports permission denial separately from other failures', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => 'permissionDenied',
    );

    final result = await AndroidPhotoSaver(channel: channel).save(jpeg);

    expect(result, isA<SaveFailed>());
    expect((result as SaveFailed).reason, SaveFailureReason.permissionDenied);
  });

  test('maps channel errors to failed without claiming success', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'storageError');
    });

    final result = await AndroidPhotoSaver(channel: channel).save(jpeg);

    expect(result, isA<SaveFailed>());
    expect((result as SaveFailed).reason, SaveFailureReason.failed);
  });
}

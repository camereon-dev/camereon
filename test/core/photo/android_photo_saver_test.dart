import 'dart:async';

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

  test('rejects concurrent saves and allows retry after completion', () async {
    final pending = Completer<String>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) {
      calls++;
      return pending.future;
    });
    final saver = AndroidPhotoSaver(channel: channel);
    final first = saver.save(jpeg);
    expect(await saver.save(jpeg), isA<SaveFailed>());
    pending.complete('saved');
    expect(await first, isA<SaveSucceeded>());
    expect(await saver.save(jpeg), isA<SaveSucceeded>());
    expect(calls, 2);
  });

  for (final status in [null, 'failed', 'unexpected']) {
    test('does not claim success for $status', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => status);
      expect(
        await AndroidPhotoSaver(channel: channel).save(jpeg),
        isA<SaveFailed>(),
      );
    });
  }

  test('missing plugin and permission exceptions map to failure', () async {
    expect(
      await AndroidPhotoSaver(channel: channel).save(jpeg),
      isA<SaveFailed>(),
    );
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'permissionDenied');
    });
    final result =
        await AndroidPhotoSaver(channel: channel).save(jpeg) as SaveFailed;
    expect(result.reason, SaveFailureReason.permissionDenied);
  });

  test('empty input never invokes the platform', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      fail('must not invoke platform');
    });
    expect(
      await AndroidPhotoSaver(channel: channel)
          .save(RedactedJpeg(bytes: Uint8List(0), width: 1, height: 1)),
      isA<SaveFailed>(),
    );
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

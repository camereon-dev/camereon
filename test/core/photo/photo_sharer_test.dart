import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_sharer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/photo_share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  final jpeg = RedactedJpeg(
    bytes: Uint8List.fromList([0xff, 0xd8, 1, 2, 0xff, 0xd9]),
    width: 1,
    height: 1,
  );

  test('shares the redacted bytes and opens the saved photo', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final sharer = PlatformPhotoSharer(channel: channel);
    expect(await sharer.share(jpeg), isTrue);
    expect(await sharer.open(), isTrue);
    expect(calls.map((c) => c.method), ['share', 'open']);
    expect((calls.first.arguments as Map)['bytes'], jpeg.bytes);
  });

  test('platform errors and missing platforms report failure', () async {
    final sharer = PlatformPhotoSharer(channel: channel);
    expect(await sharer.share(jpeg), isFalse);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'x'),
    );
    expect(await sharer.open(), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await sharer.share(jpeg), isFalse);
  });
}

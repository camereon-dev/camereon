import 'package:camereon/features/camera/device_rotation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/device_rotation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> send(Object? arguments) => messenger.handlePlatformMessage(
    'test/device_rotation',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('changed', arguments),
    ),
    (_) {},
  );

  test(
    'capture follows the natural orientation, icons follow the screen',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final rotation = DeviceRotation(channel: channel);
      expect(rotation.captureOrientation, DeviceOrientation.portraitUp);
      // Phone turned so its left side is up.
      await send({'capture': 270, 'ui': 270});
      expect(rotation.captureOrientation, DeviceOrientation.landscapeRight);
      expect(rotation.iconTurns, -.25);
      // Landscape-natural tablet held upright in the portrait-locked UI.
      await send({'capture': 90, 'ui': 0});
      expect(rotation.captureOrientation, DeviceOrientation.landscapeLeft);
      expect(rotation.iconTurns, 0);
      // Malformed messages are ignored.
      for (final bad in [
        null,
        90,
        {'capture': 45, 'ui': 0},
        {'ui': 0},
      ]) {
        await send(bad);
        expect(rotation.value, 90);
      }
      rotation.dispose();
    },
  );

  test('an unavailable sensor leaves the camera upright', () async {
    final rotation = DeviceRotation(channel: channel);
    await Future<void>.delayed(Duration.zero);
    expect(rotation.captureOrientation, DeviceOrientation.portraitUp);
    rotation.dispose();
  });
}

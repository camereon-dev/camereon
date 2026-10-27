import 'package:camereon/core/analysis/infrastructure/mlkit_face_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual resized dimensions restore axes independently and clamp margin',
    () {
      final region = restoreFaceRegion(
        const Rect.fromLTRB(10, 20, 40, 60),
        sourceWidth: 301,
        sourceHeight: 599,
        inputWidth: 100,
        inputHeight: 200,
        margin: 0,
      )!;
      expect(
        [region.left, region.top, region.right, region.bottom],
        [30, 59, 121, 180],
      );
      final edge = restoreFaceRegion(
        const Rect.fromLTRB(0, 0, 100, 200),
        sourceWidth: 301,
        sourceHeight: 599,
        inputWidth: 100,
        inputHeight: 200,
      )!;
      expect([edge.left, edge.top, edge.right, edge.bottom], [0, 0, 301, 599]);
      expect(
        restoreFaceRegion(
          const Rect.fromLTRB(5, 5, 4, 4),
          sourceWidth: 10,
          sourceHeight: 10,
          inputWidth: 10,
          inputHeight: 10,
        ),
        isNull,
      );
    },
  );
  test('channel returns candidates without any model store', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MlKitFaceDetector.channel, (call) async {
          expect(call.method, 'detect');
          return {
            'width': 100,
            'height': 200,
            'faces': [
              [10, 20, 40, 60],
            ],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MlKitFaceDetector.channel, null),
    );
    final faces = await MlKitFaceDetector().detect(
      SourcePhoto(bytes: Uint8List(0), width: 300, height: 600),
    );
    expect(faces.single.id, 'face-0');
    expect(faces.single.region.left, 21);
  });
}

import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camereon/app.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/core/detection/place_name_dictionary.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:camereon/features/camera/glass_photo_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

/// 端末のカメラの代わりに、プレビューと撮影結果を返す
class FakeCameraPlatform extends CameraPlatform {
  FakeCameraPlatform({this.cameras = const [_back, _front], this.error});

  final List<CameraDescription> cameras;
  final CameraException? error;
  final opened = <String>[];
  final captureOrientations = <DeviceOrientation>[];
  final orientationChanges =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  int pictures = 0;
  final disposed = <int>[];
  int _nextId = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => cameras;

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async {
    if (error != null) throw error!;
    opened.add(cameraDescription.name);
    return _nextId++;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          1600,
          1200,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      StreamController<CameraErrorEvent>().stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      orientationChanges.stream;

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {
    captureOrientations.add(orientation);
  }

  @override
  Widget buildPreview(int cameraId) =>
      ColoredBox(color: Colors.grey, key: ValueKey('preview-$cameraId'));

  @override
  Future<XFile> takePicture(int cameraId) async {
    pictures++;
    return XFile('/nonexistent/camereon-test.jpg');
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposed.add(cameraId);
  }
}

void main() {
  late FakeCameraPlatform camera;
  const picker = MethodChannel('dev.camereon/photo_picker');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
  });

  void useCamera(FakeCameraPlatform fake) {
    camera = fake;
    CameraPlatform.instance = fake;
  }

  testWidgets('写真の選択はカメラ権限なしでも開き、キャンセル後に再試行できる', (tester) async {
    useCamera(
      FakeCameraPlatform(
        error: CameraException('CameraAccessDenied', 'denied'),
      ),
    );
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
          calls++;
          return null;
        });
    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真を選ぶ'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('撮り直す'), findsNothing);
  });

  testWidgets('起動するとすぐに背面カメラのプレビューを表示する', (tester) async {
    useCamera(FakeCameraPlatform());
    addTearDown(camera.orientationChanges.close);

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();

    expect(camera.opened, ['back']);
    expect(camera.captureOrientations, isEmpty);
    expect(find.byKey(const ValueKey('preview-0')), findsOneWidget);
    expect(find.bySemanticsLabel('撮影する'), findsOneWidget);
  });

  Future<void> holdPhone(WidgetTester tester, int degrees) async {
    const codec = StandardMethodCodec();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'dev.camereon/device_rotation',
      codec.encodeMethodCall(
        MethodCall('changed', {'capture': degrees, 'ui': degrees}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('センサーの向きでアイコンを回し、その向きで撮影する', (tester) async {
    useCamera(FakeCameraPlatform());
    addTearDown(camera.orientationChanges.close);

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    // The plugin's display-based orientation stays portrait on a locked screen.
    camera.orientationChanges.add(
      const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp),
    );
    await holdPhone(tester, 90);
    double turns() => tester
        .widget<AnimatedRotation>(
          find.byKey(const ValueKey('camera-switch-icon')),
        )
        .turns;
    expect(turns(), .25);
    await holdPhone(tester, 270);
    expect(turns(), -.25);

    await tester.tap(find.bySemanticsLabel('撮影する'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(camera.captureOrientations, [DeviceOrientation.landscapeRight]);
    expect(camera.pictures, 1);
    expect(
      tester
          .widget<CapturedPhotoScreen>(find.byType(CapturedPhotoScreen))
          .startWithConfirmation,
      isTrue,
    );
  });

  testWidgets('向きが届かない端末（iOS）では撮影向きを固定しない', (tester) async {
    useCamera(FakeCameraPlatform());
    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('撮影する'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(camera.pictures, 1);
    expect(
      tester
          .widget<CapturedPhotoScreen>(find.byType(CapturedPhotoScreen))
          .startWithConfirmation,
      isTrue,
    );
    expect(camera.captureOrientations, isEmpty);
  });

  testWidgets('撮影すると写真の確認画面へ進み、撮り直しでカメラへ戻る', (tester) async {
    useCamera(FakeCameraPlatform());

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('撮影する'));
    await tester.pump();
    // Read failure for the fake camera's nonexistent file uses real IO.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(camera.pictures, 1);
    expect(
      tester
          .widget<CapturedPhotoScreen>(find.byType(CapturedPhotoScreen))
          .startWithConfirmation,
      isTrue,
    );
    expect(camera.disposed, contains(0));
    expect(find.byTooltip('撮り直す'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.opened, [
      'back',
    ], reason: 'Do not restart the hidden camera while editing');

    await tester.tap(find.byTooltip('撮り直す'));
    await tester.pumpAndSettle();

    expect(find.text('撮り直す'), findsNothing);
    expect(find.bySemanticsLabel('撮影する'), findsOneWidget);
    expect(camera.opened, ['back', 'back']);
  });

  testWidgets('前面と背面のカメラを切り替えられる', (tester) async {
    useCamera(FakeCameraPlatform());

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('カメラを切り替える'));
    await tester.pumpAndSettle();

    expect(camera.opened, ['back', 'front']);
    expect(find.byKey(const ValueKey('preview-1')), findsOneWidget);
  });

  testWidgets('権限を拒否されたら理由を表示し、再度許可を求められる', (tester) async {
    useCamera(
      FakeCameraPlatform(
        error: CameraException('CameraAccessDenied', 'denied'),
      ),
    );

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();

    expect(find.text('カメラの使用が許可されていません'), findsOneWidget);
    expect(find.text('設定を開く'), findsOneWidget);

    useCamera(FakeCameraPlatform());
    await tester.tap(find.text('許可する'));
    await tester.pumpAndSettle();

    expect(find.text('カメラの使用が許可されていません'), findsNothing);
    expect(camera.opened, ['back']);
  });

  testWidgets('カメラがない端末では撮影できないことを表示する', (tester) async {
    useCamera(FakeCameraPlatform(cameras: const []));

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();

    expect(find.text('カメラが見つかりません'), findsOneWidget);
  });

  testWidgets('iOSの再表示できない権限拒否は設定への案内を表示する', (tester) async {
    useCamera(
      FakeCameraPlatform(
        error: CameraException('CameraAccessDeniedWithoutPrompt', 'denied'),
      ),
    );
    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    expect(find.text('カメラの使用が許可されていません'), findsOneWidget);
    expect(find.text('設定を開く'), findsOneWidget);
    expect(find.text('許可する'), findsNothing);
    var openedSettings = false;
    const settings = MethodChannel('dev.camereon/app_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(settings, (call) async {
          openedSettings = call.method == 'open';
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(settings, null),
    );
    await tester.tap(find.text('設定を開く'));
    await tester.pumpAndSettle();
    expect(openedSettings, isTrue);
  });

  testWidgets('iOSの利用制限を通常の権限拒否と区別する', (tester) async {
    useCamera(
      FakeCameraPlatform(
        error: CameraException('CameraAccessRestricted', 'restricted'),
      ),
    );
    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();
    expect(find.text('カメラの利用が制限されています'), findsOneWidget);
    expect(find.text('許可する'), findsNothing);
    expect(find.byKey(const ValueKey('pick-photo')), findsOneWidget);
  });

  for (final denied in [false, true]) {
    testWidgets('カメラ${denied ? '権限なし' : 'なし'}でもサンプルを編集できる', (tester) async {
      await tester.runAsync(() => PlaceNameDictionary.load());
      const ocr = MethodChannel('dev.camereon/japanese_ocr');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        ocr,
        (_) async => {
          'lines': [
            [
              {
                'text': '東京都',
                'box': [80, 329, 150, 356],
              },
            ],
          ],
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(ocr, null));
      useCamera(
        FakeCameraPlatform(
          cameras: denied ? const [_back] : const [],
          error: denied
              ? CameraException('CameraAccessDenied', 'denied')
              : null,
        ),
      );
      await tester.pumpWidget(const CamereonApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-sample')));
      await tester.pump();
      // Asset loading and image normalization use real asynchronous IO/isolate work.
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.bySemanticsLabel('撮影した写真').evaluate().isNotEmpty &&
            find.byType(PhotoScanEffect).evaluate().isNotEmpty &&
            !tester
                .widget<PhotoScanEffect>(find.byType(PhotoScanEffect))
                .active) {
          break;
        }
      }
      await tester.pumpAndSettle();

      expect(camera.pictures, 0);
      expect(find.bySemanticsLabel('撮影した写真'), findsOneWidget);
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .selectedCandidates
            .single
            .kind,
        CandidateKind.address,
      );
      expect(find.byTooltip('保存前に確認'), findsOneWidget);
      final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
      await tester.dragFrom(rect.center, const Offset(30, 30));
      await tester.pump();
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byTooltip('保存前に確認'), findsOneWidget);
      await tester.tap(find.byTooltip('撮り直す'));
      await tester.pumpAndSettle();
      expect(find.text('編集を破棄しますか？'), findsOneWidget);
      await tester.tap(find.text('破棄する'));
      await tester.pumpAndSettle();
      expect(find.text('サンプルで試す'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('open-sample')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('小さい画面で文字を拡大してもレイアウトが崩れない', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    useCamera(
      FakeCameraPlatform(
        error: CameraException('CameraAccessDenied', 'denied'),
      ),
    );

    await tester.pumpWidget(const CamereonApp());
    await tester.pumpAndSettle();

    expect(find.text('許可する'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

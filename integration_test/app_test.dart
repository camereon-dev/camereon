import 'package:flutter/services.dart';

import 'package:camereon/features/camera/camera_screen.dart';
import 'package:camereon/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('端末上で起動するとカメラ画面を表示する', (tester) async {
    app.main();
    // 権限ダイアログが出ていても、カメラ画面と撮影ボタンは表示される
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(CameraScreen), findsOneWidget);
    expect(find.bySemanticsLabel('撮影する'), findsOneWidget);
    final version = await const MethodChannel('dev.camereon/app_info')
        .invokeMapMethod<String, String>('version');
    expect(version!['versionName'], isNotEmpty);
    expect(int.parse(version['versionCode']!), greaterThan(0));
    await tester.pump();
    expect(
      find.text('バージョン ${version['versionName']} (${version['versionCode']})'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

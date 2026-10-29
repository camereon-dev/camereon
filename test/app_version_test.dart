import 'package:camereon/core/app_version.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.camereon/app_info');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('shows installed version and CI build number', (tester) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'version');
      return {'versionName': '0.1.0-beta.73', 'versionCode': '73'};
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppVersion())),
    );
    await tester.pumpAndSettle();
    expect(find.text('バージョン 0.1.0-beta.73 (73)'), findsOneWidget);
  });

  testWidgets('metadata failure does not prevent camera use', (tester) async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'unavailable'),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppVersion())),
    );
    await tester.pumpAndSettle();
    expect(find.text('バージョンを取得できませんでした'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

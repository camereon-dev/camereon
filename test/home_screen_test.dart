import 'package:camereon/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('起動画面からアプリの説明を開いて戻れる', (tester) async {
    await tester.pumpWidget(const CamereonApp());

    expect(find.text('camereon'), findsOneWidget);
    expect(find.text('撮影・編集機能は今後追加予定です'), findsOneWidget);
    await tester.ensureVisible(find.text('このアプリについて'));
    await tester.tap(find.text('このアプリについて'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('安全を完全に保証するものではありません。'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('camereon'), findsOneWidget);
  });

  testWidgets('小さい画面で文字を拡大しても説明まで操作できる', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const CamereonApp());
    await tester.ensureVisible(find.text('このアプリについて'));
    await tester.tap(find.text('このアプリについて'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

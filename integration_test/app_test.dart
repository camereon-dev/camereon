import 'package:camereon/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('端末上で起動し、説明を開いて起動画面へ戻れる', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.text('camereon'), findsOneWidget);
    await tester.ensureVisible(find.text('このアプリについて'));
    await tester.tap(find.text('このアプリについて'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('camereon'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

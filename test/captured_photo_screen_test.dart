import 'dart:async';

import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart';
export 'support/photo_editor.dart';

void main() {
  for (final dimensions in [(200, 100), (100, 200)]) {
    testWidgets('$dimensions: drag and letterbox taps never add manual masks', (
      tester,
    ) async {
      await open(
        tester,
        FakeProcessor(dimensions.$1, dimensions.$2),
        FakeSaver(),
      );
      final canvas = tester.getRect(find.byKey(const ValueKey('photo-canvas')));
      final image = tester.getRect(find.bySemanticsLabel('撮影した写真'));
      expect(image.height, greaterThan(canvas.height * .5));
      await tester.dragFrom(image.center, const Offset(50, 40));
      await tester.tapAt(canvas.topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(painter(tester).regions, isEmpty);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.textContaining('ドラッグ'), findsNothing);
      expect(find.text('文字の候補を探す'), findsNothing);
    });
  }

  testWidgets(
    'candidate selection survives processing errors, undo and saving',
    (tester) async {
      final processor = FakeProcessor(200, 100)..fail = true;
      final saver = FakeSaver()
        ..result = const SaveFailed(SaveFailureReason.permissionDenied);
      final texts = FakeDetector()
        ..candidates.add(
          candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
        );
      await open(tester, processor, saver, texts: texts);
      await tapPixel(tester, const Offset(50, 40));
      final selected = painter(tester).regions.single;
      await tapText(tester, '保存前に確認');
      expect(painter(tester).regions, [selected]);
      expect(find.textContaining('加工できませんでした'), findsOneWidget);
      processor.fail = false;
      await tapText(tester, '保存前に確認');
      await tapText(tester, '写真に保存');
      expect(find.text('設定を開く'), findsOneWidget);
      await tapText(tester, '編集へ戻る');
      expect(painter(tester).regions, [selected]);
      await tapText(tester, '取り消す');
      expect(painter(tester).regions, isEmpty);
      await tapPixel(tester, const Offset(50, 40));
      await tapText(tester, '保存前に確認');
      saver.pending = Completer<SaveResult>();
      await tester.tap(find.text('写真に保存'));
      await tester.pump();
      await tester.tap(find.text('写真に保存'));
      expect(saver.calls, 2);
      saver.pending!.complete(const SaveSucceeded());
      await tester.pumpAndSettle();
      expect(find.text('写真を保存しました'), findsOneWidget);
      expect(identical(saver.received, processor.jpeg), isTrue);
    },
  );

  testWidgets('close and system back protect selected edits', (tester) async {
    final texts = FakeDetector()
      ..candidates.add(
        candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
      );
    await open(tester, FakeProcessor(200, 100), FakeSaver(), texts: texts);
    await tapPixel(tester, const Offset(50, 40));
    await tapText(tester, '撮り直す');
    expect(find.text('編集を破棄しますか？'), findsOneWidget);
    await tapText(tester, '編集を続ける');
    expect(painter(tester).regions.length, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('編集を破棄しますか？'), findsOneWidget);
  });

  testWidgets('load errors can retry', (tester) async {
    final processor = FakeProcessor(200, 100)..failLoad = true;
    await open(tester, processor, FakeSaver());
    expect(find.text('再試行'), findsOneWidget);
    processor.failLoad = false;
    await tapText(tester, '再試行');
    expect(find.bySemanticsLabel('撮影した写真'), findsOneWidget);
  });

  testWidgets('preparation takes an immutable selection snapshot', (
    tester,
  ) async {
    final processor = FakeProcessor(200, 100)..pending = Completer();
    final texts = FakeDetector()
      ..candidates.add(
        candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
      );
    await open(tester, processor, FakeSaver(), texts: texts);
    await tapPixel(tester, const Offset(50, 40));
    await tester.tap(find.byTooltip('保存前に確認'));
    await tester.pump();
    final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(processor.received, [texts.candidates.single.region]);
    processor.pending!.complete(processor.jpeg);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('保存する加工済み写真'), findsOneWidget);
  });
}

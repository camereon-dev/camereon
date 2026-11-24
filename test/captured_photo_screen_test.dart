import 'dart:async';

import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart';
export 'support/photo_editor.dart';

void main() {
  testWidgets(
    'partial detection remains editable and retries without losing selection',
    (tester) async {
      final texts = FakeDetector()
        ..partial = true
        ..candidates.add(
          candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
        );
      await open(tester, FakeProcessor(200, 100), FakeSaver(), texts: texts);
      expect(find.byTooltip('一部を検出できませんでした'), findsOneWidget);
      await tapPixel(tester, const Offset(50, 40));
      final selected = painter(tester).regions.single;
      texts.partial = false;
      await tapText(tester, '一部を検出できませんでした');
      expect(texts.calls, 2);
      expect(find.byTooltip('一部を検出できませんでした'), findsNothing);
      expect(painter(tester).regions, [selected]);
    },
  );

  for (final dimensions in [(200, 100), (100, 200)]) {
    testWidgets('$dimensions: one finger paints, letterbox taps add nothing', (
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
      await tester.tapAt(canvas.topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(painter(tester).regions, isEmpty);
      await tester.dragFrom(image.center, const Offset(50, 40));
      await tester.pumpAndSettle();
      final stroke = painter(tester).regions.single;
      expect(stroke.shape, HideShape.stroke);
      expect(stroke.reveal, isFalse);
      // No instructions on the editor: icons and frames only.
      expect(find.textContaining('タップ'), findsNothing);
      expect(find.textContaining('ドラッグ'), findsNothing);
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
      await tapText(tester, '写真に保存');
      expect(painter(tester).regions, [selected]);
      expect(find.textContaining('加工できませんでした'), findsOneWidget);
      expect(saver.calls, 0);
      processor.fail = false;
      await tapText(tester, '写真に保存');
      expect(saver.calls, 1);
      expect(find.text('設定を開く'), findsOneWidget);
      expect(painter(tester).regions, [selected]);
      await tapText(tester, '取り消す');
      expect(painter(tester).regions, isEmpty);
      await tapText(tester, 'やり直す');
      expect(painter(tester).regions, [selected]);
      saver.pending = Completer<SaveResult>();
      await tester.tap(find.byTooltip('写真に保存'));
      await tester.pump();
      // A second tap while saving does nothing.
      await tester.tap(find.byTooltip('写真に保存'));
      expect(saver.calls, 2);
      saver.pending!.complete(const SaveSucceeded());
      await tester.pumpAndSettle();
      expect(find.byTooltip('共有'), findsOneWidget);
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

  testWidgets('saving takes an immutable selection snapshot', (tester) async {
    final processor = FakeProcessor(200, 100)..pending = Completer();
    final texts = FakeDetector()
      ..candidates.add(
        candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
      );
    await open(tester, processor, FakeSaver(), texts: texts);
    await tapPixel(tester, const Offset(50, 40));
    await tester.tap(find.byTooltip('写真に保存'));
    await tester.pump();
    final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(processor.received, [texts.candidates.single.region]);
    expect(painter(tester).regions, [texts.candidates.single.region]);
    processor.pending!.complete(processor.jpeg);
    await tester.pumpAndSettle();
    expect(find.byTooltip('共有'), findsOneWidget);
  });

  testWidgets('after saving, the photo can be shared or opened at once', (
    tester,
  ) async {
    final processor = FakeProcessor(200, 100);
    final sharer = FakeSharer();
    final saver = FakeSaver();
    final texts = FakeDetector()
      ..candidates.add(
        candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
      );
    await open(tester, processor, saver, texts: texts, sharer: sharer);
    await tapPixel(tester, const Offset(50, 40));
    expect(find.byTooltip('共有'), findsNothing);
    await tapText(tester, '写真に保存');
    await tapText(tester, '共有');
    expect(sharer.shared, [processor.jpeg]);
    await tapText(tester, '写真アプリで開く');
    expect(sharer.opened, 1);
    sharer.result = false;
    await tapText(tester, '共有');
    expect(find.text('共有できませんでした'), findsOneWidget);
    expect(find.byTooltip('もう一枚'), findsOneWidget);
    // Saved, so leaving does not ask.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('編集を破棄しますか？'), findsNothing);
  });

  testWidgets('editing after saving offers to save again', (tester) async {
    final processor = FakeProcessor(200, 100);
    final saver = FakeSaver();
    final texts = FakeDetector()
      ..candidates.add(
        candidate(CandidateKind.text, const Rect.fromLTRB(20, 20, 80, 60)),
      );
    await open(tester, processor, saver, texts: texts);
    await tapPixel(tester, const Offset(50, 40));
    await tapText(tester, '写真に保存');
    expect(find.byTooltip('写真に保存'), findsNothing);
    await tapPixel(tester, const Offset(50, 40));
    expect(find.byTooltip('写真に保存'), findsOneWidget);
    await tapText(tester, '写真に保存');
    expect(saver.calls, 2);
    expect(processor.received, isEmpty);
  });
}

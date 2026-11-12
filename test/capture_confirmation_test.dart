import 'dart:async';

import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

void main() {
  final address = editor.candidate(
    CandidateKind.address,
    const Rect.fromLTRB(20, 20, 70, 40),
  );
  for (final edit in [false, true]) {
    testWidgets('capture confirms first then saves (edit: $edit)', (
      tester,
    ) async {
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      await editor.open(
        tester,
        processor,
        saver,
        addresses: editor.FakeDetector()..candidates.add(address),
        includeOtherCandidates: false,
        startWithConfirmation: true,
      );
      expect(find.byType(CandidateOverlay), findsNothing);
      expect(find.text('写真に保存'), findsOneWidget);
      expect(processor.received, [address.region]);
      if (edit) {
        await editor.tapText(tester, '編集する');
        expect(editor.overlay(tester).selectedCandidates, {address});
        await editor.tapPixel(tester, const Offset(45, 30));
        await editor.tapText(tester, '保存前に確認');
        expect(processor.received, isEmpty);
        expect(find.byType(CandidateOverlay), findsNothing);
      }
      await editor.tapText(tester, '写真に保存');
      expect(saver.received, same(processor.jpeg));
    });
  }

  testWidgets('confirmation waits for detection and retries failures', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final detector = editor.FakeDetector()
      ..pending = Completer<RegionDetection>();
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      addresses: detector,
      includeOtherCandidates: false,
      startWithConfirmation: true,
      settle: false,
    );
    expect(find.byType(CandidateOverlay), findsNothing);
    expect(find.text('写真に保存'), findsNothing);
    expect(processor.received, isNull);
    detector.pending!.completeError(const RegionDetectionException());
    await tester.pumpAndSettle();
    expect(find.text('写真に保存'), findsNothing);
    expect(find.text('一部を検出できませんでした'), findsOneWidget);
    detector.pending = null;
    detector.candidates.add(address);
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(find.text('写真に保存'), findsOneWidget);
    expect(processor.received, [address.region]);
  });

  testWidgets('failed confirmation rendering can be retried', (tester) async {
    final processor = editor.FakeProcessor(200, 100)..fail = true;
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      addresses: editor.FakeDetector()..candidates.add(address),
      includeOtherCandidates: false,
      startWithConfirmation: true,
    );
    expect(find.text('写真に保存'), findsNothing);
    expect(find.byType(CandidateOverlay), findsNothing);
    processor.fail = false;
    await editor.tapText(tester, '確認画像を再作成');
    expect(find.text('写真に保存'), findsOneWidget);
    expect(processor.received, [address.region]);
  });
}

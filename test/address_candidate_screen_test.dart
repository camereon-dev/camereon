import 'dart:async';

import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/sample_address_candidates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

void main() {
  for (final revealBeforeSave in [false, true]) {
    testWidgets('address starts hidden, toggles and saves selection '
        '(revealed: $revealBeforeSave)', (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      final addresses = [
        editor.candidate(
          CandidateKind.address,
          const Rect.fromLTRB(20, 20, 90, 40),
        ),
        editor.candidate(
          CandidateKind.address,
          const Rect.fromLTRB(110, 60, 190, 80),
        ),
      ];
      await editor.open(
        tester,
        processor,
        saver,
        initialCandidates: (_) => addresses,
      );
      expect(editor.overlay(tester).selectedCandidates, addresses.toSet());
      expect(
        editor.painter(tester).regions,
        addresses.map((candidate) => candidate.region),
      );

      await editor.tapPixel(tester, const Offset(50, 30));
      expect(editor.overlay(tester).selectedCandidates, {addresses.last});
      await editor.tapText(tester, '取り消す');
      expect(editor.overlay(tester).selectedCandidates, addresses.toSet());
      await editor.tapPixel(tester, const Offset(50, 30));
      await editor.tapPixel(tester, const Offset(50, 30));
      expect(editor.overlay(tester).selectedCandidates, addresses.toSet());
      await editor.tapText(tester, '保存前に確認');
      await editor.tapText(tester, '編集へ戻る');
      expect(editor.overlay(tester).selectedCandidates, addresses.toSet());
      if (revealBeforeSave) {
        await editor.tapPixel(tester, const Offset(50, 30));
      }
      await editor.tapText(tester, '保存前に確認');
      expect(
        processor.received,
        unorderedEquals([
          if (!revealBeforeSave) addresses.first.region,
          addresses.last.region,
        ]),
      );
      saver.result = const SaveFailed(SaveFailureReason.failed);
      await editor.tapText(tester, '写真に保存');
      expect(saver.received, same(processor.jpeg));
      saver.result = const SaveSucceeded();
      await editor.tapText(tester, '写真に保存');
      expect(saver.calls, 2);
      expect(find.text('写真を保存しました'), findsOneWidget);
    });
  }

  testWidgets('late OCR and retry do not reapply a revealed address', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final address = editor.candidate(
      CandidateKind.address,
      const Rect.fromLTRB(20, 20, 90, 40),
    );
    final text = editor.candidate(
      CandidateKind.text,
      const Rect.fromLTRB(25, 25, 85, 35),
    );
    final detector = editor.FakeDetector()
      ..pending = Completer<RegionDetection>();
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      texts: detector,
      initialCandidates: (_) => [address],
      settle: false,
    );
    expect(editor.painter(tester).regions, [address.region]);
    // Avoid settling while the scan animation is running.
    final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
    await tester.tapAt(rect.topLeft + Offset(rect.width / 4, rect.height * .3));
    await tester.pump();
    detector.pending!.complete(
      RegionDetection(candidates: [text], partial: true),
    );
    await tester.pumpAndSettle();
    expect(editor.overlay(tester).candidates, [address]);
    expect(editor.painter(tester).regions, isEmpty);
    detector.pending = null;
    detector.candidates.add(text);
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(editor.painter(tester).regions, isEmpty);
    await editor.tapPixel(tester, const Offset(50, 30));
    expect(editor.painter(tester).regions, [address.region]);
  });

  testWidgets('sample address supports clearing all and saving no masks', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(640, 640);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      initialCandidates: sampleAddressCandidates,
    );
    expect(
      editor.painter(tester).regions.single.toRect(),
      const Rect.fromLTRB(76, 325, 431, 360),
    );
    await editor.tapText(tester, '住所 1');
    expect(editor.painter(tester).regions, isEmpty);
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, isEmpty);
    await editor.tapText(tester, '写真に保存');
    expect(saver.received, same(processor.jpeg));
  });
}

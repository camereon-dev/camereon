import 'dart:async';

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/japanese_address_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

class _PendingFaces implements PhotoFaceDetector {
  final result = Completer<List<FaceCandidate>>();

  @override
  Future<List<FaceCandidate>> detect(SourcePhoto photo) => result.future;
}

void main() {
  final address = editor.candidate(
    CandidateKind.address,
    const Rect.fromLTRB(20, 20, 70, 40),
  );

  testWidgets('a capture opens the editor with addresses hidden and saves', (
    tester,
  ) async {
    final candidates = japaneseAddressCandidates(
      [
        [const AddressGlyph('〒100-0001', Rect.fromLTRB(20, 10, 90, 30))],
        [const AddressGlyph('東京都', Rect.fromLTRB(20, 60, 80, 80))],
      ],
      200,
      100,
    );
    expect(candidates, hasLength(2));
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      addresses: editor.FakeDetector()..candidates.addAll(candidates),
      includeOtherCandidates: false,
    );
    // No confirmation step: the editor is the result.
    expect(editor.overlay(tester).selectedCandidates, candidates.toSet());
    expect(processor.received, isNull);
    await editor.tapPixel(tester, const Offset(50, 20));
    expect(editor.overlay(tester).selectedCandidates, {candidates.last});
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, [candidates.last.region]);
    expect(saver.received, same(processor.jpeg));
  });

  testWidgets('while detecting the photo is unreadable and cannot be saved', (
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
      settle: false,
    );
    expect(find.byType(CandidateOverlay), findsNothing);
    expect(find.bySemanticsLabel('撮影した写真'), findsNothing);
    expect(find.bySemanticsLabel('検出中'), findsOneWidget);
    await tester.tap(find.byTooltip('写真に保存'));
    await tester.pump();
    expect(processor.received, isNull);
    detector.pending!.completeError(const RegionDetectionException());
    await tester.pumpAndSettle();
    expect(find.byTooltip('一部を検出できませんでした'), findsOneWidget);

    // Saving after a failed scan asks first; retrying finds the address.
    detector.pending = null;
    detector.candidates.add(address);
    await editor.tapText(tester, '写真に保存');
    expect(find.text('このまま保存'), findsOneWidget);
    await editor.tapText(tester, 'もう一度検出');
    expect(processor.received, isNull);
    expect(editor.overlay(tester).selectedCandidates, {address});
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, [address.region]);
  });

  testWidgets('an interrupted face scan still requires confirmation', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    final faces = _PendingFaces();
    await editor.open(
      tester,
      processor,
      saver,
      faces: faces,
      includeOtherCandidates: false,
      settle: false,
    );
    expect(find.bySemanticsLabel('検出中'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await editor.tapText(tester, '写真に保存');
    expect(find.text('このまま保存'), findsOneWidget);
    expect(processor.received, isNull);
    expect(saver.calls, 0);

    faces.result.complete([FaceCandidate('face', address.region)]);
    await tester.pumpAndSettle();
    await editor.tapText(tester, 'このまま保存');
    expect(saver.calls, 1);
  });

  testWidgets('a scan that adds a mask after saving requires a fresh save', (
    tester,
  ) async {
    final addresses = editor.FakeDetector()..partial = true;
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      addresses: addresses,
      includeOtherCandidates: false,
    );
    await editor.tapText(tester, '写真に保存');
    await editor.tapText(tester, 'このまま保存');
    expect(processor.received, isEmpty);
    expect(find.byTooltip('共有'), findsOneWidget);

    addresses
      ..partial = false
      ..candidates.add(address);
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(find.byTooltip('共有'), findsNothing);
    expect(saver.calls, 1);
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, [address.region]);
    expect(saver.calls, 2);
  });

  testWidgets('a failed save keeps the edits for another attempt', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100)..fail = true;
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      addresses: editor.FakeDetector()..candidates.add(address),
      includeOtherCandidates: false,
    );
    await editor.tapText(tester, '写真に保存');
    expect(find.textContaining('加工できませんでした'), findsOneWidget);
    expect(saver.calls, 0);
    expect(editor.overlay(tester).selectedCandidates, {address});
    processor.fail = false;
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, [address.region]);
    expect(saver.calls, 1);
  });

  testWidgets('leaving asks only after the user changed something', (
    tester,
  ) async {
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      addresses: editor.FakeDetector()..candidates.add(address),
      includeOtherCandidates: false,
    );
    // Automatic masks alone can be recomputed: no question.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('編集を破棄しますか？'), findsNothing);
  });

  testWidgets('leaving after an edit asks before discarding it', (
    tester,
  ) async {
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      addresses: editor.FakeDetector()..candidates.add(address),
      includeOtherCandidates: false,
    );
    await editor.tapPixel(tester, const Offset(45, 30));
    await editor.tapText(tester, '撮り直す');
    expect(find.text('編集を破棄しますか？'), findsOneWidget);
  });
}

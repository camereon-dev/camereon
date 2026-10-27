import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'captured_photo_screen_test.dart' as existing;

class FakeDetector implements RegionDetector {
  int calls = 0;
  bool fail = false;
  Completer<RegionDetection>? pending;
  final candidates = [
    for (final r in [
      const Rect.fromLTRB(20, 10, 80, 30),
      const Rect.fromLTRB(100, 10, 180, 30),
      const Rect.fromLTRB(20, 45, 80, 65),
      const Rect.fromLTRB(100, 45, 180, 65),
    ])
      RegionCandidate(
        kind: CandidateKind.text,
        region: HideRegion.fromRect(r, imageWidth: 200, imageHeight: 100)!,
      ),
  ];
  @override
  Future<RegionDetection> detect(SourcePhoto photo) async {
    calls++;
    if (fail) throw const RegionDetectionException();
    return pending == null
        ? RegionDetection(candidates: candidates)
        : pending!.future;
  }
}

Future<void> open(
  WidgetTester tester,
  FakeDetector detector,
  existing.FakeProcessor processor,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CapturedPhotoScreen(
        photo: XFile.fromData(processor.source.bytes),
        processor: processor,
        saver: existing.FakeSaver(),
        detector: detector,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'four fixed buttons toggle independently without changing order or position',
    (tester) async {
      final detector = FakeDetector();
      final processor = existing.FakeProcessor(200, 100);
      await open(tester, detector, processor);
      await tap(tester, '文字の候補を探す');
      // Compare positions within the row: scrolling the combined face/text
      // controls may legitimately move the entire row on screen.
      List<Offset> positions() => [
        for (var i = 0; i < 4; i++)
          tester.getCenter(find.byKey(ValueKey('candidate-toggle-$i'))) -
              tester.getTopLeft(
                find.byKey(const ValueKey('candidate-toggle-0')),
              ),
      ];
      List<bool> selected() => tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .map((chip) => chip.selected)
          .toList();
      final initialPositions = positions();
      expect(selected(), [false, false, false, false]);
      await tap(tester, '文字候補 1');
      expect(selected(), [true, false, false, false]);
      expect(positions(), initialPositions);
      await tap(tester, '文字候補 3');
      await tap(tester, '文字候補 1');
      expect(selected(), [false, false, true, false]);
      expect(positions(), initialPositions);
      expect(existing.painter(tester).regions, [detector.candidates[2].region]);
      final overlay = tester.widget<CandidateOverlay>(
        find.byType(CandidateOverlay),
      );
      expect(overlay.candidates, detector.candidates);
      expect(overlay.selectedRegions, {detector.candidates[2].region});
      await tap(tester, '保存前に確認');
      expect(processor.received, [detector.candidates[2].region]);
      await tap(tester, '編集へ戻る');
      expect(selected(), [false, false, true, false]);
      await tap(tester, 'すべてリセット');
      expect(selected(), [false, false, false, false]);
      expect(existing.painter(tester).regions, isEmpty);
      for (var i = 1; i <= 4; i++) {
        expect(find.text('文字候補 $i'), findsOneWidget);
      }
    },
  );

  testWidgets('deselecting a matching candidate retains the manual selection', (
    tester,
  ) async {
    final detector = FakeDetector();
    await open(tester, detector, existing.FakeProcessor(200, 100));
    await existing.select(tester);
    final manual = existing.painter(tester).regions.single;
    detector.candidates[0] = RegionCandidate(
      kind: CandidateKind.text,
      region: manual,
    );
    await tap(tester, '文字の候補を探す');
    await tap(tester, '文字候補 1');
    expect(existing.painter(tester).regions, [manual]);
    await tap(tester, '文字候補 1');
    expect(existing.painter(tester).regions, [manual]);
    expect(
      tester
          .widget<FilterChip>(find.byKey(const ValueKey('candidate-toggle-0')))
          .selected,
      isFalse,
    );
    await tap(tester, '取り消す');
    expect(existing.painter(tester).regions, isEmpty);
  });

  testWidgets('toggle, reset and rerun preserve manual edits', (tester) async {
    final detector = FakeDetector();
    final processor = existing.FakeProcessor(200, 100);
    await open(tester, detector, processor);
    await existing.select(
      tester,
      start: const Offset(.05, .85),
      end: const Offset(.2, .95),
    );
    final manual = existing.painter(tester).regions.single;
    await tap(tester, '文字の候補を探す');
    expect(existing.painter(tester).regions, [manual]);
    expect(
      tester
          .widget<CandidateOverlay>(find.byType(CandidateOverlay))
          .candidates
          .length,
      4,
    );
    await tap(tester, '文字候補 1');
    expect(existing.painter(tester).regions, [
      manual,
      detector.candidates.first.region,
    ]);
    await tap(tester, '文字候補 1');
    expect(existing.painter(tester).regions, [manual]);
    await tap(tester, '候補をすべて適用');
    expect(existing.painter(tester).regions.length, 5);
    await tap(tester, '文字の候補を探す');
    expect(existing.painter(tester).regions.length, 5);
    await tap(tester, '保存前に確認');
    expect(processor.received, [
      manual,
      ...detector.candidates.map((c) => c.region),
    ]);
    await tap(tester, '編集へ戻る');
    await tap(tester, 'すべてリセット');
    expect(existing.painter(tester).regions, isEmpty);
    expect(find.text('候補をすべて適用'), findsOneWidget);
  });

  testWidgets(
    'failed scan retains manual edits and candidates and permits retry',
    (tester) async {
      final detector = FakeDetector();
      await open(tester, detector, existing.FakeProcessor(200, 100));
      await existing.select(tester);
      await tap(tester, '文字の候補を探す');
      detector.fail = true;
      await tap(tester, '文字の候補を探す');
      expect(find.textContaining('検出できませんでした'), findsOneWidget);
      expect(existing.painter(tester).regions.length, 1);
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .candidates
            .length,
        4,
      );
      detector.fail = false;
      await tap(tester, '文字の候補を探す');
      expect(detector.calls, 3);
    },
  );

  testWidgets(
    'late detection cannot overwrite confirmation; duplicate start is blocked',
    (tester) async {
      final detector = FakeDetector()..pending = Completer<RegionDetection>();
      await open(tester, detector, existing.FakeProcessor(200, 100));
      await tester.ensureVisible(find.text('文字の候補を探す'));
      await tester.tap(find.text('文字の候補を探す'));
      await tester.pump();
      await tester.tap(find.text('文字候補を探しています…'));
      expect(detector.calls, 1);
      await tap(tester, '保存前に確認');
      detector.pending!.complete(
        RegionDetection(candidates: detector.candidates),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('保存する加工済み写真'), findsOneWidget);
      await tap(tester, '編集へ戻る');
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .candidates,
        isEmpty,
      );
    },
  );
}

import 'dart:async';

import 'package:camereon/core/detection/region_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;
export 'support/photo_editor.dart' show FakeDetector;

Future<void> tap(WidgetTester tester, String label) =>
    editor.tapText(tester, label);

void main() {
  testWidgets('text and object frames toggle independently and undo together', (
    tester,
  ) async {
    final texts = editor.FakeDetector()
      ..candidates.addAll([
        editor.candidate(
          CandidateKind.text,
          const Rect.fromLTRB(20, 10, 80, 30),
        ),
        editor.candidate(
          CandidateKind.text,
          const Rect.fromLTRB(100, 10, 180, 30),
        ),
      ]);
    final objects = editor.FakeDetector()
      ..candidates.add(
        editor.candidate(
          CandidateKind.person,
          const Rect.fromLTRB(20, 65, 180, 95),
        ),
      );
    final processor = editor.FakeProcessor(200, 100);
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      texts: texts,
      objects: objects,
    );
    await editor.tapPixel(tester, const Offset(50, 20));
    await editor.tapPixel(tester, const Offset(80, 80));
    expect(editor.painter(tester).regions, [
      texts.candidates.first.region,
      objects.candidates.single.region,
    ]);
    await tap(tester, '取り消す');
    expect(editor.painter(tester).regions, [texts.candidates.first.region]);
    await tap(tester, '保存前に確認');
    expect(processor.received, [texts.candidates.first.region]);
    await tap(tester, '編集へ戻る');
    expect(editor.overlay(tester).selectedCandidates, {texts.candidates.first});
  });

  testWidgets(
    'a failed detector retains other candidates and retry preserves identity',
    (tester) async {
      final texts = editor.FakeDetector()..fail = true;
      final objects = editor.FakeDetector()
        ..candidates.add(
          editor.candidate(
            CandidateKind.screen,
            const Rect.fromLTRB(20, 10, 80, 70),
          ),
        );
      await editor.open(
        tester,
        editor.FakeProcessor(200, 100),
        editor.FakeSaver(),
        texts: texts,
        objects: objects,
      );
      await editor.tapPixel(tester, const Offset(50, 40));
      expect(find.text('一部を検出できませんでした'), findsOneWidget);
      texts.fail = false;
      texts.candidates.add(
        editor.candidate(
          CandidateKind.text,
          const Rect.fromLTRB(110, 10, 180, 40),
        ),
      );
      await tap(tester, '一部を検出できませんでした');
      expect((texts.calls, objects.calls), (2, 2));
      expect(editor.overlay(tester).selectedCandidates, {
        objects.candidates.single,
      });
      expect(editor.overlay(tester).candidates.length, 2);
    },
  );

  testWidgets('confirmation cancels queued scans and ignores late results', (
    tester,
  ) async {
    final texts = editor.FakeDetector()..pending = Completer<RegionDetection>();
    final objects = editor.FakeDetector();
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      texts: texts,
      objects: objects,
      settle: false,
    );
    expect(texts.calls, 1);
    await tester.tap(find.byTooltip('保存前に確認'));
    await tester.pumpAndSettle();
    texts.pending!.complete(
      RegionDetection(
        candidates: [
          editor.candidate(
            CandidateKind.text,
            const Rect.fromLTRB(20, 10, 80, 30),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(objects.calls, 0);
    await tap(tester, '編集へ戻る');
    expect(editor.overlay(tester).candidates, isEmpty);
    texts.pending = null;
    texts.candidates.add(
      editor.candidate(CandidateKind.text, const Rect.fromLTRB(20, 10, 80, 30)),
    );
    await tap(tester, '一部を検出できませんでした');
    expect((texts.calls, objects.calls), (2, 1));
    expect(editor.overlay(tester).candidates.length, 1);
  });
}

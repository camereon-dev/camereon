import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'captured_photo_screen_test.dart' as editor;
import 'face_candidate_screen_test.dart' as face;
import 'text_region_candidates_test.dart' as text;

void main() {
  testWidgets(
    'face, person and text selections stay independent on one shared region',
    (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      final faces = face.ControlledFaces();
      final texts = text.FakeDetector();
      final objects = text.FakeDetector();
      final shared = texts.candidates.first.region;
      objects.candidates
        ..clear()
        ..add(RegionCandidate(kind: CandidateKind.person, region: shared));
      faces.result.complete([FaceCandidate('face-0', shared)]);
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(processor.source.bytes),
            processor: processor,
            saver: editor.FakeSaver(),
            faceDetector: faces,
            detector: texts,
            objectDetector: objects,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await editor.select(
        tester,
        start: const Offset(.05, .85),
        end: const Offset(.2, .95),
      );
      final manual = editor.painter(tester).regions.single;
      await text.tap(tester, '人物・画面の候補を探す');
      await text.tap(tester, '人物候補 1');
      await text.tap(tester, '顔 1：適用');
      await text.tap(tester, '文字の候補を探す');
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '文字候補 2'))
            .selected,
        isFalse,
        reason:
            'A selected person must not preselect text at the same coordinates',
      );
      await text.tap(tester, '文字候補 2');
      expect(editor.painter(tester).regions, [manual, shared]);
      await text.tap(tester, '顔 1：解除');
      await text.tap(tester, '人物候補 1');
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '人物候補 1'))
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '文字候補 2'))
            .selected,
        isTrue,
      );
      expect(editor.painter(tester).regions, [manual, shared]);
      await text.tap(tester, '文字候補 2');
      expect(editor.painter(tester).regions, [manual]);
      await text.tap(tester, '人物・画面の候補を探す');
      expect(find.text('文字候補 2'), findsOneWidget);
      expect(editor.painter(tester).regions, [manual]);
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<FaceCandidatePainter>()
          .single;
      expect(painter.labels, ['顔1']);
      expect(painter.candidates.single.kind, CandidateKind.face);
    },
  );

  testWidgets(
    'overlapping face/text remain independent through history and save',
    (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      final faces = face.ControlledFaces();
      final texts = text.FakeDetector();
      final shared = texts.candidates.first.region;
      faces.result.complete([FaceCandidate('face-0', shared)]);
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(processor.source.bytes),
            processor: processor,
            saver: saver,
            faceDetector: faces,
            detector: texts,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await editor.select(
        tester,
        start: const Offset(.05, .85),
        end: const Offset(.2, .95),
      );
      final manual = editor.painter(tester).regions.single;
      await text.tap(tester, '文字の候補を探す');
      await text.tap(tester, '顔 1：適用');
      await text.tap(tester, '文字候補 1');
      expect(editor.painter(tester).regions, [manual, shared]);
      await text.tap(tester, '顔 1：解除');
      expect(editor.painter(tester).regions, [manual, shared]);
      await text.tap(
        tester,
        '取り消す',
      ); // Restore the face, retain text selection.
      await text.tap(tester, '文字候補 1'); // Text off must retain the face.
      expect(editor.painter(tester).regions, [manual, shared]);
      await text.tap(tester, '候補をすべて適用'); // main's text-only batch action.
      await text.tap(tester, '保存前に確認');
      expect(processor.received, [
        manual,
        ...texts.candidates.map((c) => c.region),
      ]);
      await text.tap(tester, '写真に保存');
      expect(saver.calls, 1);
      expect(identical(saver.received, processor.jpeg), isTrue);
    },
  );

  testWidgets('reset clears both candidate selections and face history', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final faces = face.ControlledFaces();
    final texts = text.FakeDetector();
    faces.result.complete([
      FaceCandidate('face-0', texts.candidates.first.region),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: CapturedPhotoScreen(
          photo: XFile.fromData(processor.source.bytes),
          processor: processor,
          saver: editor.FakeSaver(),
          faceDetector: faces,
          detector: texts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await text.tap(tester, '文字の候補を探す');
    await text.tap(tester, '顔 1：適用');
    await text.tap(tester, '候補をすべて適用');
    await text.tap(tester, 'すべてリセット');
    expect(editor.painter(tester).regions, isEmpty);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取り消す'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .every((c) => !c.selected),
      isTrue,
    );
    await text.tap(tester, '顔 1：適用');
    await text.tap(tester, '取り消す');
    expect(editor.painter(tester).regions, isEmpty);
  });
}

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_candidate_screen_test.dart' show ControlledFaces;
import 'support/photo_editor.dart' as editor;

void main() {
  testWidgets(
    'coincident face/person/text can be chosen independently from image',
    (tester) async {
      final shared = editor.region(const Rect.fromLTRB(20, 20, 100, 70));
      final faces = ControlledFaces()
        ..result.complete([FaceCandidate('face', shared)]);
      final texts = editor.FakeDetector()
        ..candidates.add(
          RegionCandidate(kind: CandidateKind.text, region: shared),
        );
      final objects = editor.FakeDetector()
        ..candidates.add(
          RegionCandidate(kind: CandidateKind.person, region: shared),
        );
      final processor = editor.FakeProcessor(200, 100);
      await editor.open(
        tester,
        processor,
        editor.FakeSaver(),
        texts: texts,
        objects: objects,
        faces: faces,
      );
      await editor.tapPixel(tester, const Offset(50, 40));
      await editor.tapText(tester, '人物を隠す');
      expect(editor.overlay(tester).selectedCandidates, {
        objects.candidates.single,
      });
      await editor.tapPixel(tester, const Offset(50, 40));
      await editor.tapText(tester, '文字を隠す');
      expect(editor.painter(tester).regions, [shared]);
      expect(editor.overlay(tester).selectedCandidates.length, 2);
      await editor.tapPixel(tester, const Offset(50, 40));
      await editor.tapText(tester, '人物を表示する');
      expect(editor.overlay(tester).selectedCandidates, {
        texts.candidates.single,
      });
      await editor.tapText(tester, '取り消す');
      expect(editor.overlay(tester).selectedCandidates.length, 2);
      await editor.tapText(tester, '保存前に確認');
      expect(processor.received, [shared]);
    },
  );

  testWidgets(
    'text frames that mostly share a face are hidden once the face arrives',
    (tester) async {
      final faces = ControlledFaces();
      final texts = editor.FakeDetector()
        ..candidates.addAll([
          // Eyes/glasses inside the face, and a scarf edge enclosing the face.
          editor.candidate(
            CandidateKind.text,
            const Rect.fromLTRB(30, 30, 60, 45),
          ),
          editor.candidate(
            CandidateKind.text,
            const Rect.fromLTRB(10, 10, 120, 90),
          ),
          // A name tag beside the face stays available.
          editor.candidate(
            CandidateKind.text,
            const Rect.fromLTRB(130, 20, 190, 40),
          ),
        ]);
      final processor = editor.FakeProcessor(200, 100);
      await editor.open(
        tester,
        processor,
        editor.FakeSaver(),
        texts: texts,
        faces: faces,
        settle: false,
      );
      await tester.pump();
      expect(editor.overlay(tester).candidates.length, 3);
      // Selecting before the face arrives keeps that frame visible afterwards.
      // The scan animation is still running, so pump once instead of settling.
      final image = tester.getRect(find.bySemanticsLabel('撮影した写真'));
      await tester.tapAt(
        image.topLeft + Offset(45 / 200 * image.width, 38 / 100 * image.height),
      );
      await tester.pump();
      expect(editor.overlay(tester).selectedCandidates, {texts.candidates[0]});
      faces.result.complete([
        FaceCandidate(
          'face',
          editor.region(const Rect.fromLTRB(20, 20, 100, 70)),
        ),
      ]);
      await tester.pumpAndSettle();
      final visible = editor.overlay(tester).candidates;
      expect(visible.map((c) => c.kind), [
        CandidateKind.face,
        CandidateKind.text,
        CandidateKind.text,
      ]);
      expect(visible, isNot(contains(texts.candidates[1])));
      expect(visible, contains(texts.candidates[0]));
      expect(visible, contains(texts.candidates[2]));
      await editor.tapText(tester, '保存前に確認');
      expect(processor.received, [texts.candidates[0].region]);
    },
  );
}

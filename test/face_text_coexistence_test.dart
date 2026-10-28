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
}

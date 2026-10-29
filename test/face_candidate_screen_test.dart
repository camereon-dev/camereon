import 'dart:async';

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

class ControlledFaces implements PhotoFaceDetector {
  final result = Completer<List<FaceCandidate>>();
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) => result.future;
}

void main() {
  testWidgets('late face frames appear and support tap, undo and save', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    final faces = ControlledFaces();
    await editor.open(tester, processor, saver, faces: faces, settle: false);
    final r = editor.region(const Rect.fromLTRB(20, 20, 60, 60));
    faces.result.complete([FaceCandidate('one', r)]);
    await tester.pumpAndSettle();
    await editor.tapPixel(tester, const Offset(40, 40));
    expect(editor.painter(tester).regions, [r]);
    await editor.tapPixel(tester, const Offset(40, 40));
    expect(editor.painter(tester).regions, isEmpty);
    await editor.tapText(tester, '取り消す');
    expect(editor.painter(tester).regions, [r]);
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, [r]);
    await editor.tapText(tester, '写真に保存');
    expect(saver.calls, 1);
  });

  testWidgets('saving while face detection runs ignores late faces', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final faces = ControlledFaces();
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      faces: faces,
      settle: false,
    );
    await tester.tap(find.byTooltip('保存前に確認'));
    await tester.pumpAndSettle();
    faces.result.complete([
      FaceCandidate('late', editor.region(const Rect.fromLTRB(20, 20, 60, 60))),
    ]);
    await tester.pumpAndSettle();
    expect(processor.received, isEmpty);
    await editor.tapText(tester, '編集へ戻る');
    expect(editor.overlay(tester).candidates, isEmpty);
  });
}

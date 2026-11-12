import 'dart:async';

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

class Faces implements PhotoFaceDetector {
  final candidates = [
    FaceCandidate(
      'face-0',
      editor.region(const Rect.fromLTRB(120, 20, 180, 80)),
    ),
  ];
  Completer<List<FaceCandidate>>? pending;
  bool fail = false;
  int calls = 0;
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) async {
    calls++;
    if (fail) throw StateError('test failure');
    return pending == null ? candidates : pending!.future;
  }
}

void main() {
  testWidgets(
    'addresses and faces start hidden and toggle independently through save',
    (tester) async {
      final address = editor.candidate(
        CandidateKind.address,
        const Rect.fromLTRB(20, 20, 80, 40),
      );
      final addresses = editor.FakeDetector()
        ..candidates.add(address)
        ..partial = true;
      final faces = Faces();
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      final texts = editor.FakeDetector();
      final objects = editor.FakeDetector();
      await editor.open(
        tester,
        processor,
        saver,
        addresses: addresses,
        faces: faces,
        texts: texts,
        objects: objects,
        includeOtherCandidates: false,
      );
      expect(faces.calls, 1);
      expect(texts.calls, 0);
      expect(objects.calls, 0);
      expect(
        editor.painter(tester).regions,
        unorderedEquals([address.region, faces.candidates.single.region]),
      );
      await editor.tapPixel(tester, const Offset(150, 50));
      expect(editor.painter(tester).regions, [address.region]);
      await editor.tapText(tester, '一部を検出できませんでした');
      expect(editor.painter(tester).regions, [address.region]);
      await editor.tapPixel(tester, const Offset(150, 50));
      await editor.tapPixel(tester, const Offset(50, 30));
      expect(editor.painter(tester).regions, [faces.candidates.single.region]);
      await editor.tapText(tester, '保存前に確認');
      expect(processor.received, [faces.candidates.single.region]);
      await editor.tapText(tester, '写真に保存');
      expect(saver.received, same(processor.jpeg));
    },
  );

  testWidgets('save waits for faces as well as OCR', (tester) async {
    final faces = Faces()..pending = Completer<List<FaceCandidate>>();
    final processor = editor.FakeProcessor(200, 100);
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      faces: faces,
      includeOtherCandidates: false,
      settle: false,
    );
    await tester.tap(find.byTooltip('保存前に確認'));
    await tester.pump();
    expect(processor.received, isNull);
    expect(find.bySemanticsLabel('撮影した写真'), findsNothing);
    faces.pending!.complete(faces.candidates);
    await tester.pumpAndSettle();
    expect(editor.painter(tester).regions, [faces.candidates.single.region]);
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, [faces.candidates.single.region]);
  });

  testWidgets('retry discovers faces without undo revealing them', (
    tester,
  ) async {
    final faces = Faces()..fail = true;
    final address = editor.candidate(
      CandidateKind.address,
      const Rect.fromLTRB(20, 20, 80, 40),
    );
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      addresses: editor.FakeDetector()..candidates.add(address),
      faces: faces,
      includeOtherCandidates: false,
    );
    await editor.tapPixel(tester, const Offset(50, 30));
    faces.fail = false;
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(editor.painter(tester).regions, [faces.candidates.single.region]);
    await editor.tapText(tester, '取り消す');
    expect(
      editor.painter(tester).regions,
      unorderedEquals([address.region, faces.candidates.single.region]),
    );
  });
}

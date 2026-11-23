import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/frosted_preview.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

class _Faces implements PhotoFaceDetector {
  final face = FaceCandidate(
    'face-0',
    editor.region(const Rect.fromLTRB(120, 20, 180, 80)),
  );
  int calls = 0;
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) async {
    calls++;
    return [face];
  }
}

void main() {
  final address = editor.candidate(
    CandidateKind.address,
    const Rect.fromLTRB(20, 20, 80, 40),
  );

  Future<(editor.FakeProcessor, _Faces, editor.FakeDetector)> open(
    WidgetTester tester, {
    required Set<CandidateKind> autoHideKinds,
    bool startWithConfirmation = false,
    List<RegionCandidate> Function(SourcePhoto)? initialCandidates,
  }) async {
    final processor = editor.FakeProcessor(200, 100);
    final faces = _Faces();
    final addresses = editor.FakeDetector()..candidates.add(address);
    await tester.pumpWidget(
      MaterialApp(
        home: CapturedPhotoScreen(
          photo: XFile.fromData(processor.source.bytes),
          processor: processor,
          saver: editor.FakeSaver(),
          faceDetector: faces,
          addressDetector: addresses,
          previewer: const FrostedPreviewer.none(),
          sharer: editor.FakeSharer(),
          startWithConfirmation: startWithConfirmation,
          initialCandidates: initialCandidates,
          autoHideKinds: autoHideKinds,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (processor, faces, addresses);
  }

  testWidgets('a kind not hidden automatically is framed but starts visible', (
    tester,
  ) async {
    final (processor, faces, addresses) = await open(
      tester,
      autoHideKinds: {CandidateKind.address},
    );
    final face = editor
        .overlay(tester)
        .candidates
        .singleWhere((c) => c.kind == CandidateKind.face);
    expect(faces.calls, 1, reason: 'detection still runs');
    expect(addresses.calls, 1);
    expect(editor.overlay(tester).candidates, contains(address));
    expect(editor.overlay(tester).selectedCandidates, {address});
    expect(editor.painter(tester).regions, [address.region]);

    await editor.tapPixel(tester, const Offset(150, 50));
    expect(editor.overlay(tester).selectedCandidates, {address, face});
    await editor.tapText(tester, '取り消す');
    expect(editor.overlay(tester).selectedCandidates, {address});
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, [address.region]);
  });

  testWidgets('addresses can start visible while faces are hidden', (
    tester,
  ) async {
    final (processor, faces, _) = await open(
      tester,
      autoHideKinds: {CandidateKind.face},
      initialCandidates: (_) => [
        editor.candidate(
          CandidateKind.address,
          const Rect.fromLTRB(20, 60, 80, 80),
        ),
      ],
    );
    final overlay = editor.overlay(tester);
    expect(
      overlay.candidates.where((c) => c.kind == CandidateKind.address),
      hasLength(2),
    );
    expect(overlay.selectedCandidates.map((c) => c.kind), [CandidateKind.face]);

    await editor.tapPixel(tester, const Offset(50, 30));
    expect(editor.overlay(tester).selectedCandidates, contains(address));
    await editor.tapText(tester, '保存前に確認');
    expect(
      processor.received,
      unorderedEquals([address.region, faces.face.region]),
    );
  });

  testWidgets('with nothing hidden automatically, capture confirms as shot', (
    tester,
  ) async {
    final (processor, _, _) = await open(
      tester,
      autoHideKinds: const {},
      startWithConfirmation: true,
    );
    expect(processor.received, isEmpty);
    await editor.tapText(tester, '編集する');
    expect(editor.overlay(tester).candidates, hasLength(2));
    expect(editor.overlay(tester).selectedCandidates, isEmpty);
  });
}

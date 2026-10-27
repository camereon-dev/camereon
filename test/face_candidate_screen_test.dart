import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'captured_photo_screen_test.dart' as support;

class ControlledFaces implements PhotoFaceDetector {
  final result = Completer<List<FaceCandidate>>();
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) => result.future;
}

void main() {
  testWidgets('manual edits, face apply/remove, undo, reset and save coexist', (
    tester,
  ) async {
    final processor = support.FakeProcessor(200, 100);
    final saver = support.FakeSaver();
    final detector = ControlledFaces();
    await tester.pumpWidget(
      MaterialApp(
        home: CapturedPhotoScreen(
          photo: XFile.fromData(processor.source.bytes),
          processor: processor,
          saver: saver,
          faceDetector: detector,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await support.select(tester);
    final manual = support.painter(tester).regions.single;
    detector.result.complete([
      FaceCandidate(
        'one',
        HideRegion.fromRect(
          const Rect.fromLTRB(20, 20, 60, 60),
          imageWidth: 200,
          imageHeight: 100,
        )!,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(support.painter(tester).regions, [manual]);
    await tester.tap(find.text('顔 1：適用'));
    await tester.pumpAndSettle();
    expect(support.painter(tester).regions.length, 2);
    await tester.tap(find.text('顔 1：解除'));
    await tester.pumpAndSettle();
    expect(support.painter(tester).regions, [manual]);
    await tester.tap(find.text('取り消す'));
    await tester.pumpAndSettle();
    expect(support.painter(tester).regions.length, 2);
    await tester.tap(find.text('すべてリセット'));
    await tester.pumpAndSettle();
    expect(support.painter(tester).regions, isEmpty);
    expect(find.text('顔 1：適用'), findsOneWidget);
    await tester.tap(find.text('顔 1：適用'));
    await tester.pumpAndSettle();
    final applied = support.painter(tester).regions.single;
    await tester.tap(find.text('保存前に確認'));
    await tester.pumpAndSettle();
    expect(processor.received, [applied]);
    await tester.tap(find.text('写真に保存'));
    await tester.pumpAndSettle();
    expect(saver.calls, 1);
    expect(identical(saver.received, processor.jpeg), isTrue);
  });

  testWidgets('saving during detection excludes late candidates', (
    tester,
  ) async {
    final processor = support.FakeProcessor(200, 100);
    final detector = ControlledFaces();
    await tester.pumpWidget(
      MaterialApp(
        home: CapturedPhotoScreen(
          photo: XFile.fromData(processor.source.bytes),
          processor: processor,
          saver: support.FakeSaver(),
          faceDetector: detector,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await support.select(tester);
    final manual = support.painter(tester).regions.single;
    await tester.tap(find.text('保存前に確認'));
    await tester.pumpAndSettle();
    detector.result.complete([FaceCandidate('late', manual)]);
    await tester.pumpAndSettle();
    expect(processor.received, [manual]);
    await tester.tap(find.text('編集へ戻る'));
    await tester.pumpAndSettle();
    expect(find.text('顔 1：適用'), findsNothing);
    expect(support.painter(tester).regions, [manual]);
    expect(find.text('顔検出を再試行'), findsOneWidget);
  });
}

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'captured_photo_screen_test.dart' as editor;
import 'text_region_candidates_test.dart' as text;

class CountingFaces implements PhotoFaceDetector {
  CountingFaces(this.candidates);
  final List<FaceCandidate> candidates;
  int calls = 0;
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto photo) async {
    calls++;
    return candidates;
  }
}

HideRegion region(Rect rect) =>
    HideRegion.fromRect(rect, imageWidth: 200, imageHeight: 100)!;

Future<void> tapPixel(
  WidgetTester tester,
  Offset pixel, {
  Offset? jitter,
}) async {
  final image = tester.getRect(find.bySemanticsLabel('撮影した写真'));
  final point =
      image.topLeft +
      Offset(pixel.dx / 200 * image.width, pixel.dy / 100 * image.height);
  final gesture = await tester.startGesture(point);
  if (jitter != null) await gesture.moveBy(jitter);
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('deferred loading starts automatic detection when app resumes', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final processor = editor.FakeProcessor(200, 100);
    final faces = CountingFaces([]);
    final texts = text.FakeDetector();
    final objects = text.FakeDetector()..candidates.clear();
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
    expect((faces.calls, texts.calls, objects.calls), (0, 0, 0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect((faces.calls, texts.calls, objects.calls), (1, 1, 1));
  });

  testWidgets('all detectors start automatically, ONNX scans run in sequence', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final faces = CountingFaces([]);
    final texts = text.FakeDetector()..pending = Completer<RegionDetection>();
    final objects = text.FakeDetector()..candidates.clear();
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
    await tester.pump();
    await tester.pump();
    expect(faces.calls, 1);
    expect(texts.calls, 1);
    expect(objects.calls, 0);
    texts.pending!.complete(RegionDetection(candidates: texts.candidates));
    await tester.pumpAndSettle();
    expect(objects.calls, 1);
    expect(editor.painter(tester).regions, isEmpty);
    await tester.pump();
    expect(texts.calls, 1);
    expect(faces.calls, 1);
  });

  testWidgets('one failed automatic detector does not skip the other', (
    tester,
  ) async {
    final texts = text.FakeDetector()..fail = true;
    final objects = text.FakeDetector();
    objects.candidates
      ..clear()
      ..add(
        RegionCandidate(
          kind: CandidateKind.person,
          region: region(const Rect.fromLTRB(10, 10, 190, 90)),
        ),
      );
    await text.open(
      tester,
      texts,
      editor.FakeProcessor(200, 100),
      objectDetector: objects,
    );
    expect((texts.calls, objects.calls), (1, 1));
    expect(find.textContaining('文字候補を検出できませんでした'), findsOneWidget);
    expect(find.text('人物候補 1'), findsOneWidget);
    await tapPixel(tester, const Offset(100, 50));
    expect(editor.painter(tester).regions, [objects.candidates.single.region]);
  });

  testWidgets(
    'image taps choose nested face/screen and outer frame independently',
    (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      final faceRegion = region(const Rect.fromLTRB(40, 20, 80, 55));
      final person = RegionCandidate(
        kind: CandidateKind.person,
        region: region(const Rect.fromLTRB(10, 5, 190, 95)),
      );
      final screen = RegionCandidate(
        kind: CandidateKind.screen,
        region: region(const Rect.fromLTRB(100, 45, 165, 80)),
      );
      final objects = text.FakeDetector()..candidates.clear();
      objects.candidates.addAll([person, screen]);
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(processor.source.bytes),
            processor: processor,
            saver: editor.FakeSaver(),
            faceDetector: CountingFaces([FaceCandidate('one', faceRegion)]),
            detector: editor.NoRegions(),
            objectDetector: objects,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapPixel(tester, const Offset(60, 35), jitter: const Offset(2, 1));
      expect(editor.painter(tester).regions, [faceRegion]);
      await tapPixel(tester, const Offset(60, 35));
      expect(editor.painter(tester).regions, isEmpty);
      await tapPixel(tester, const Offset(130, 60));
      expect(editor.painter(tester).regions, [screen.region]);
      await tapPixel(tester, const Offset(12, 50));
      expect(
        editor.painter(tester).regions,
        containsAll([screen.region, person.region]),
      );
      await tapPixel(tester, const Offset(130, 60));
      expect(editor.painter(tester).regions, [person.region]);
      await tapPixel(tester, const Offset(12, 50));
      await tapPixel(tester, const Offset(195, 99));
      expect(editor.painter(tester).regions, isEmpty);
      // A real drag starting inside a candidate still creates a manual region.
      await editor.select(
        tester,
        start: const Offset(.25, .25),
        end: const Offset(.45, .65),
      );
      expect(editor.painter(tester).regions.single, isNot(faceRegion));
    },
  );

  testWidgets(
    'face-only view applies just faces and retains previous edits through save',
    (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      final faceRegion = region(const Rect.fromLTRB(40, 20, 80, 55));
      final texts = text.FakeDetector();
      await tester.pumpWidget(
        MaterialApp(
          home: CapturedPhotoScreen(
            photo: XFile.fromData(processor.source.bytes),
            processor: processor,
            saver: saver,
            faceDetector: CountingFaces([FaceCandidate('one', faceRegion)]),
            detector: texts,
            objectDetector: editor.NoRegions(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await text.tap(tester, '顔だけ');
      expect(
        tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .candidates,
        isEmpty,
      );
      await tapPixel(
        tester,
        const Offset(140, 20),
      ); // Hidden text cannot be tapped.
      expect(editor.painter(tester).regions, isEmpty);
      await text.tap(tester, '顔をすべて適用');
      expect(editor.painter(tester).regions, [faceRegion]);
      await text.tap(tester, 'すべての候補');
      await text.tap(tester, '文字候補 2');
      await text.tap(tester, '顔だけ');
      expect(editor.painter(tester).regions, [
        faceRegion,
        texts.candidates[1].region,
      ]);
      await tapPixel(tester, const Offset(60, 35));
      expect(editor.painter(tester).regions, [texts.candidates[1].region]);
      await text.tap(tester, '顔をすべて適用');
      await text.tap(tester, '保存前に確認');
      expect(processor.received, [faceRegion, texts.candidates[1].region]);
      await text.tap(tester, '写真に保存');
      expect(saver.calls, 1);
    },
  );
}

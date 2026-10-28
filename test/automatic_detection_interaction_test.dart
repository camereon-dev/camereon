import 'dart:async';

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/camera/glass_photo_chrome.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

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

void main() {
  testWidgets('candidate frames expose independent accessible tap actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      final texts = editor.FakeDetector()
        ..candidates.add(
          editor.candidate(
            CandidateKind.text,
            const Rect.fromLTRB(20, 20, 80, 60),
          ),
        );
      await editor.open(
        tester,
        editor.FakeProcessor(200, 100),
        editor.FakeSaver(),
        texts: texts,
      );
      SemanticsNode? target;
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().label == '文字の候補 1') target = node;
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(CandidateOverlay)));
      expect(target, isNotNull);
      expect(target!.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      target!.owner!.performAction(target!.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(editor.painter(tester).regions, [texts.candidates.single.region]);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('reduced motion leaves detection active without a moving scan', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final texts = editor.FakeDetector()..pending = Completer<RegionDetection>();
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      texts: texts,
      settle: false,
    );
    // Settling would time out if the scan ticker still repeated.
    await tester.pumpAndSettle();
    expect(
      tester.widget<PhotoScanEffect>(find.byType(PhotoScanEffect)).active,
      isTrue,
    );
    texts.pending!.complete(RegionDetection(candidates: const []));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PhotoScanEffect>(find.byType(PhotoScanEffect)).active,
      isFalse,
    );
  });

  testWidgets(
    'all detectors start automatically and ONNX scans stay sequential',
    (tester) async {
      final faces = CountingFaces([]);
      final texts = editor.FakeDetector()
        ..pending = Completer<RegionDetection>();
      final objects = editor.FakeDetector();
      await editor.open(
        tester,
        editor.FakeProcessor(200, 100),
        editor.FakeSaver(),
        faces: faces,
        texts: texts,
        objects: objects,
        settle: false,
      );
      expect((faces.calls, texts.calls, objects.calls), (1, 1, 0));
      expect(
        tester.widget<PhotoScanEffect>(find.byType(PhotoScanEffect)).active,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('検出中'), findsOneWidget);
      texts.pending!.complete(RegionDetection(candidates: texts.candidates));
      await tester.pumpAndSettle();
      expect((faces.calls, texts.calls, objects.calls), (1, 1, 1));
      expect(
        tester.widget<PhotoScanEffect>(find.byType(PhotoScanEffect)).active,
        isFalse,
      );
      expect(editor.painter(tester).regions, isEmpty);
    },
  );

  testWidgets('deferred loading starts when the app resumes', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final faces = CountingFaces([]);
    final texts = editor.FakeDetector();
    final objects = editor.FakeDetector();
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      faces: faces,
      texts: texts,
      objects: objects,
    );
    expect((faces.calls, texts.calls, objects.calls), (0, 0, 0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect((faces.calls, texts.calls, objects.calls), (1, 1, 1));
  });

  testWidgets(
    'nested face/screen and the outer person frame toggle independently',
    (tester) async {
      final faceRegion = editor.region(const Rect.fromLTRB(40, 20, 80, 55));
      final person = editor.candidate(
        CandidateKind.person,
        const Rect.fromLTRB(10, 5, 190, 95),
      );
      final screen = editor.candidate(
        CandidateKind.screen,
        const Rect.fromLTRB(100, 45, 165, 80),
      );
      final objects = editor.FakeDetector()
        ..candidates.addAll([person, screen]);
      await editor.open(
        tester,
        editor.FakeProcessor(200, 100),
        editor.FakeSaver(),
        faces: CountingFaces([FaceCandidate('one', faceRegion)]),
        objects: objects,
      );
      await editor.tapPixel(tester, const Offset(60, 35));
      expect(editor.painter(tester).regions, [faceRegion]);
      await editor.tapPixel(tester, const Offset(130, 60));
      await editor.tapPixel(tester, const Offset(12, 50));
      expect(
        editor.painter(tester).regions,
        containsAll([faceRegion, screen.region, person.region]),
      );
      await editor.tapPixel(tester, const Offset(130, 60));
      expect(
        editor.painter(tester).regions,
        containsAll([faceRegion, person.region]),
      );
      await editor.tapText(tester, '取り消す');
      expect(editor.painter(tester).regions, contains(screen.region));
    },
  );

  testWidgets(
    'face-only view hides other frames and preserves already selected masks',
    (tester) async {
      final faceRegion = editor.region(const Rect.fromLTRB(40, 20, 80, 55));
      final texts = editor.FakeDetector()
        ..candidates.add(
          editor.candidate(
            CandidateKind.text,
            const Rect.fromLTRB(110, 10, 180, 30),
          ),
        );
      final processor = editor.FakeProcessor(200, 100);
      await editor.open(
        tester,
        processor,
        editor.FakeSaver(),
        texts: texts,
        faces: CountingFaces([FaceCandidate('one', faceRegion)]),
      );
      await editor.tapText(tester, '顔だけ');
      expect(
        editor
            .overlay(tester)
            .candidates
            .every((c) => c.kind == CandidateKind.face),
        isTrue,
      );
      await editor.tapPixel(tester, const Offset(140, 20));
      expect(editor.painter(tester).regions, isEmpty);
      await editor.tapPixel(tester, const Offset(60, 35));
      await editor.tapText(tester, 'すべて');
      await editor.tapPixel(tester, const Offset(140, 20));
      await editor.tapText(tester, '顔だけ');
      expect(editor.painter(tester).regions, [
        faceRegion,
        texts.candidates.single.region,
      ]);
      await editor.tapText(tester, '保存前に確認');
      expect(processor.received, [faceRegion, texts.candidates.single.region]);
    },
  );

  testWidgets('glass controls fit a narrow display with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await editor.open(
      tester,
      editor.FakeProcessor(100, 200),
      editor.FakeSaver(),
    );
    expect(find.byType(PhotoGlass), findsNWidgets(3));
    await editor.tapText(tester, '顔だけ');
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.bySemanticsLabel('撮影した写真')).height,
      greaterThan(300),
    );
  });
}

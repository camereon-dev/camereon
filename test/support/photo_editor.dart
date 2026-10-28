import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_processor.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class NoRegions implements RegionDetector {
  @override
  Future<RegionDetection> detect(SourcePhoto photo) async =>
      RegionDetection(candidates: const []);
}

class NoFaces implements PhotoFaceDetector {
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto photo) async => const [];
}

class FakeProcessor implements PhotoProcessor {
  FakeProcessor(int width, int height) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(220, 220, 220));
    source = SourcePhoto(
      bytes: img.encodePng(image),
      width: width,
      height: height,
    );
    jpeg = RedactedJpeg(
      bytes: img.encodeJpg(image),
      width: width,
      height: height,
    );
  }
  late SourcePhoto source;
  late RedactedJpeg jpeg;
  List<HideRegion>? received;
  bool fail = false;
  bool failLoad = false;
  Completer<RedactedJpeg>? pending;

  @override
  Future<SourcePhoto> normalize(Uint8List bytes) async {
    if (failLoad) throw StateError('load');
    return source;
  }

  @override
  Future<RedactedJpeg> redact(
    SourcePhoto photo,
    List<HideRegion> regions,
  ) async {
    expect(identical(photo, source), isTrue);
    received = List.of(regions);
    if (fail) throw StateError('processing');
    return pending == null ? jpeg : pending!.future;
  }
}

class FakeSaver implements PhotoSaver {
  SaveResult result = const SaveSucceeded();
  int calls = 0;
  RedactedJpeg? received;
  Completer<SaveResult>? pending;
  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    calls++;
    received = jpeg;
    return pending == null ? result : pending!.future;
  }
}

SelectionPainter painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is CustomPaint && widget.painter is SelectionPainter,
              ),
            )
            .painter!
        as SelectionPainter;

class FakeDetector implements RegionDetector {
  int calls = 0;
  bool fail = false;
  bool truncated = false;
  Completer<RegionDetection>? pending;
  final List<RegionCandidate> candidates = [];
  @override
  Future<RegionDetection> detect(SourcePhoto source) async {
    calls++;
    if (fail) throw const RegionDetectionException();
    return pending == null
        ? RegionDetection(candidates: candidates, truncated: truncated)
        : pending!.future;
  }
}

HideRegion region(Rect r) =>
    HideRegion.fromRect(r, imageWidth: 200, imageHeight: 100)!;
RegionCandidate candidate(CandidateKind kind, Rect r) =>
    RegionCandidate(kind: kind, region: region(r));
CandidateOverlay overlay(WidgetTester tester) =>
    tester.widget<CandidateOverlay>(find.byType(CandidateOverlay));
Future<void> open(
  WidgetTester tester,
  FakeProcessor processor,
  FakeSaver saver, {
  RegionDetector? texts,
  RegionDetector? objects,
  PhotoFaceDetector? faces,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CapturedPhotoScreen(
        photo: XFile.fromData(processor.source.bytes),
        processor: processor,
        saver: saver,
        detector: texts ?? NoRegions(),
        objectDetector: objects ?? NoRegions(),
        faceDetector: faces ?? NoFaces(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
}

Future<void> tapText(WidgetTester tester, String label) async {
  final text = find.text(label);
  final target = text.evaluate().isNotEmpty ? text : find.byTooltip(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> tapPixel(
  WidgetTester tester,
  Offset point, {
  int width = 200,
  int height = 100,
}) async {
  final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
  await tester.tapAt(
    rect.topLeft +
        Offset(point.dx / width * rect.width, point.dy / height * rect.height),
  );
  await tester.pumpAndSettle();
}

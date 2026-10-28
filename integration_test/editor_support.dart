import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> editorAction(WidgetTester tester, String label) async {
  final text = find.text(label);
  final target = text.evaluate().isNotEmpty ? text : find.byTooltip(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> tapCandidate(
  WidgetTester tester,
  RegionCandidate candidate,
) async {
  final overlay = tester.widget<CandidateOverlay>(
    find.byType(CandidateOverlay),
  );
  final image = tester.getRect(find.bySemanticsLabel('撮影した写真'));
  final center = candidate.region.toRect().center;
  await tester.tapAt(
    image.topLeft +
        Offset(
          center.dx / overlay.imageWidth * image.width,
          center.dy / overlay.imageHeight * image.height,
        ),
  );
  await tester.pumpAndSettle();
}

/// Isolate oriented-coordinate/save testing from model accuracy on a color grid.
class CoordinateFixtureDetector implements RegionDetector {
  @override
  Future<RegionDetection> detect(SourcePhoto source) async => RegionDetection(
    candidates: [
      RegionCandidate(
        kind: CandidateKind.text,
        region: HideRegion.fromRect(
          Rect.fromLTRB(
            source.width * .1,
            source.height * .1,
            source.width * .6,
            source.height * .6,
          ),
          imageWidth: source.width,
          imageHeight: source.height,
        )!,
      ),
    ],
  );
}

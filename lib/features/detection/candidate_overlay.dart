import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../core/detection/region_detector.dart';
import '../../core/photo/hide_region.dart';
import '../camera/glass_photo_chrome.dart';

/// Frames are the controls. Selection is keyed by candidate, never geometry.
class CandidateOverlay extends StatelessWidget {
  const CandidateOverlay({
    super.key,
    required this.candidates,
    required this.imageWidth,
    required this.imageHeight,
    this.selectedCandidates = const {},
    this.onToggle,
  });
  final List<RegionCandidate> candidates;
  final int imageWidth;
  final int imageHeight;
  final Set<RegionCandidate> selectedCandidates;
  final ValueChanged<RegionCandidate>? onToggle;
  Set<HideRegion> get selectedRegions => {
    for (final c in selectedCandidates) c.region,
  };

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: ValueKey(Object.hashAll(candidates)),
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 420),
    curve: Curves.easeOutCubic,
    builder: (context, value, _) => CustomPaint(
      painter: CandidatePainter(
        candidates: candidates,
        selected: selectedCandidates,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        reveal: value,
        onToggle: onToggle,
      ),
    ),
  );
}

class CandidatePainter extends CustomPainter {
  CandidatePainter({
    required this.candidates,
    required this.selected,
    required this.imageWidth,
    required this.imageHeight,
    required this.reveal,
    this.onToggle,
  });
  final List<RegionCandidate> candidates;
  final Set<RegionCandidate> selected;
  final int imageWidth;
  final int imageHeight;
  final double reveal;
  final ValueChanged<RegionCandidate>? onToggle;

  Rect _rect(RegionCandidate c, Size size) => Rect.fromLTRB(
    c.region.left * size.width / imageWidth,
    c.region.top * size.height / imageHeight,
    c.region.right * size.width / imageWidth,
    c.region.bottom * size.height / imageHeight,
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final candidate in candidates) {
      final applied = selected.contains(candidate);
      final rect = _rect(candidate, size).inflate((1 - reveal) * 6);
      final radius = math.min(8.0, rect.shortestSide / 5);
      final color = applied ? glassMint : Colors.white;
      final frame = RRect.fromRectAndRadius(rect, Radius.circular(radius));
      canvas.drawRRect(
        frame,
        Paint()
          ..color = Colors.black.withValues(alpha: .4 * reveal)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      if (!applied) {
        canvas.drawRRect(
          frame,
          Paint()..color = glassMint.withValues(alpha: .045 * reveal),
        );
      }
      canvas.drawRRect(
        frame,
        Paint()
          ..color = color.withValues(alpha: (applied ? .85 : .5) * reveal)
          ..style = PaintingStyle.stroke
          ..strokeWidth = applied ? 1.6 : 1,
      );
      final edge = Paint()
        ..color = color.withValues(alpha: reveal)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final length = math.min(14.0, rect.shortestSide / 3);
      for (final (corner, dx, dy) in [
        (rect.topLeft, 1.0, 1.0),
        (rect.topRight, -1.0, 1.0),
        (rect.bottomLeft, 1.0, -1.0),
        (rect.bottomRight, -1.0, -1.0),
      ]) {
        canvas.drawPath(
          Path()
            ..moveTo(corner.dx, corner.dy + dy * length)
            ..lineTo(corner.dx, corner.dy + dy * radius)
            ..quadraticBezierTo(
              corner.dx,
              corner.dy,
              corner.dx + dx * radius,
              corner.dy,
            )
            ..lineTo(corner.dx + dx * length, corner.dy),
          edge,
        );
      }
      if (applied && rect.width >= 28 && rect.height >= 28) {
        final center = rect.topRight + const Offset(-12, 12);
        canvas.drawCircle(
          center,
          8,
          Paint()..color = glassMint.withValues(alpha: reveal),
        );
        canvas.drawPath(
          Path()
            ..moveTo(center.dx - 3, center.dy)
            ..lineTo(center.dx - .5, center.dy + 2.5)
            ..lineTo(center.dx + 3.5, center.dy - 2.5),
          Paint()
            ..color = const Color(0xFF142A25).withValues(alpha: reveal)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    canvas.restore();
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (var i = 0; i < candidates.length; i++)
          CustomPainterSemantics(
            key: ObjectKey(candidates[i]),
            rect: _rect(candidates[i], size),
            properties: SemanticsProperties(
              label: '${candidates[i].kind.label}の候補 ${i + 1}',
              textDirection: TextDirection.ltr,
              button: true,
              toggled: selected.contains(candidates[i]),
              onTap: onToggle == null ? null : () => onToggle!(candidates[i]),
            ),
          ),
      ];
  @override
  bool shouldRepaint(CandidatePainter oldDelegate) =>
      oldDelegate.candidates != candidates ||
      oldDelegate.selected != selected ||
      oldDelegate.reveal != reveal ||
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight;
  @override
  bool shouldRebuildSemantics(CandidatePainter oldDelegate) =>
      shouldRepaint(oldDelegate);
}

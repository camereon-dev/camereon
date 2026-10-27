import 'package:flutter/material.dart';

import '../../core/detection/region_detector.dart';
import '../../core/photo/hide_region.dart';

/// One overlay for all candidate kinds. Candidates are outlines, not redactions.
class CandidateOverlay extends StatelessWidget {
  const CandidateOverlay({
    super.key,
    required this.candidates,
    required this.imageWidth,
    required this.imageHeight,
    this.selectedRegions = const {},
  });
  final List<RegionCandidate> candidates;
  final int imageWidth;
  final int imageHeight;
  final Set<HideRegion> selectedRegions;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: CandidatePainter(
      candidates,
      imageWidth,
      imageHeight,
      selectedRegions,
    ),
  );
}

class CandidatePainter extends CustomPainter {
  CandidatePainter(
    this.candidates,
    this.imageWidth,
    this.imageHeight,
    this.selectedRegions,
  );
  final List<RegionCandidate> candidates;
  final int imageWidth;
  final int imageHeight;
  final Set<HideRegion> selectedRegions;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / imageWidth;
    final sy = size.height / imageHeight;
    final outline = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i < candidates.length; i++) {
      final r = candidates[i].region;
      final rect = Rect.fromLTRB(
        r.left * sx,
        r.top * sy,
        r.right * sx,
        r.bottom * sy,
      );
      final color = selectedRegions.contains(r)
          ? Colors.greenAccent
          : Colors.amber;
      outline.color = color;
      canvas.drawRect(rect, outline);
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: Colors.black,
            backgroundColor: color,
            fontSize: 14,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, rect.topLeft);
      label.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CandidatePainter oldDelegate) =>
      oldDelegate.candidates != candidates ||
      oldDelegate.selectedRegions != selectedRegions ||
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight;
}

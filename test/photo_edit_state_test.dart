import 'dart:ui';

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/features/camera/photo_edit_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'individual removal preserves same-geometry manual edits; undo and reset',
    () {
      final state = PhotoEditState();
      final r = HideRegion.fromRect(
        const Rect.fromLTRB(1, 1, 9, 9),
        imageWidth: 10,
        imageHeight: 10,
      )!;
      final face = FaceCandidate('face', r);
      state.addManual(r);
      state.toggle(face);
      state.toggle(face);
      expect(state.regions, [r]);
      state.undo();
      expect(state.isApplied(face.id), isTrue);
      expect(state.regions, [r, r]);
      state.undo();
      expect(state.regions, [r]);
      state.reset();
      expect(state.regions, isEmpty);
      expect(state.canUndo, isFalse);
    },
  );
}

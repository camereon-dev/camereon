import '../../core/analysis/face_detection.dart';
import '../../core/photo/hide_region.dart';

typedef EditRegion = ({HideRegion region, String? candidateId});

/// Geometry equality must never remove an overlapping manual selection.
class PhotoEditState {
  List<EditRegion> _entries = [];
  final List<List<EditRegion>> _history = [];
  List<HideRegion> get regions =>
      List.unmodifiable(_entries.map((e) => e.region));
  bool get canUndo => _history.isNotEmpty;
  bool isApplied(String id) => _entries.any((e) => e.candidateId == id);

  void addManual(HideRegion region) {
    _history.add(List.of(_entries));
    _entries.add((region: region, candidateId: null));
  }

  void toggle(FaceCandidate candidate) {
    _history.add(List.of(_entries));
    if (isApplied(candidate.id)) {
      _entries.removeWhere((e) => e.candidateId == candidate.id);
    } else {
      _entries.add((region: candidate.region, candidateId: candidate.id));
    }
  }

  void undo() {
    if (canUndo) _entries = _history.removeLast();
  }

  void reset() {
    _entries.clear();
    _history.clear();
  }
}

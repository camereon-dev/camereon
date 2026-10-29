import '../photo/hide_region.dart';
import '../photo/photo_images.dart';

class FaceCandidate {
  const FaceCandidate(this.id, this.region);
  final String id;
  final HideRegion region;
}

abstract interface class PhotoFaceDetector {
  Future<List<FaceCandidate>> detect(SourcePhoto source);
}

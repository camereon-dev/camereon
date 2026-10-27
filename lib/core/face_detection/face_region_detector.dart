import 'dart:ui';

import '../photo/photo_images.dart';

abstract interface class FaceRegionDetector {
  Future<List<Rect>> detectFaces(SourcePhoto photo, {String? imagePath});
  Future<void> close();
}

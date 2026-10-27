import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    as mlkit;

import '../photo/photo_images.dart';
import 'face_region_detector.dart';

class MlKitFaceRegionDetector implements FaceRegionDetector {
  MlKitFaceRegionDetector()
    : _detector = mlkit.FaceDetector(
        options: mlkit.FaceDetectorOptions(
          performanceMode: mlkit.FaceDetectorMode.fast,
          enableLandmarks: false,
          enableContours: false,
          enableClassification: false,
          enableTracking: false,
        ),
      );

  final mlkit.FaceDetector _detector;

  @override
  Future<List<Rect>> detectFaces(SourcePhoto photo, {String? imagePath}) async {
    if (imagePath == null || imagePath.isEmpty) return const [];
    final faces = await _detector.processImage(
      mlkit.InputImage.fromFilePath(imagePath),
    );
    return [for (final face in faces) face.boundingBox];
  }

  @override
  Future<void> close() => _detector.close();
}

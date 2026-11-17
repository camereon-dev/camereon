import 'dart:ui';

import '../../core/detection/region_detector.dart';
import '../../core/photo/hide_region.dart';
import '../../core/photo/photo_images.dart';

/// Mock only for parcel_ja.png (640 x 640), based on its synthetic ground truth.
/// This is not address detection and must not be used with arbitrary photos.
List<RegionCandidate> sampleAddressCandidates(SourcePhoto photo) => [
  RegionCandidate(
    kind: CandidateKind.address,
    region: HideRegion.fromRect(
      Rect.fromLTRB(
        76 / 640 * photo.width,
        325 / 640 * photo.height,
        431 / 640 * photo.width,
        360 / 640 * photo.height,
      ),
      imageWidth: photo.width,
      imageHeight: photo.height,
    )!,
  ),
];

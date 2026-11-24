import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../../core/detection/address_detection_mode.dart';
import '../../core/detection/region_detector.dart';

/// Kinds the settings screen offers to hide automatically, in display order.
/// Adding a detected kind here adds its switch; it starts on for everyone.
const autoHideChoices = [CandidateKind.phone, CandidateKind.face];

/// Capture resolutions the camera screen can open with.
enum CameraResolution {
  hd(ResolutionPreset.high),
  fullHd(ResolutionPreset.veryHigh),
  uhd(ResolutionPreset.ultraHigh);

  const CameraResolution(this.preset);

  /// Devices without this size fall back to the closest one they support.
  final ResolutionPreset preset;
}

@immutable
class AppSettings {
  const AppSettings({
    this.autoHideDisabled = const {},
    this.resolution = CameraResolution.fullHd,
    this.showGrid = false,
    this.addressMode = AddressDetectionMode.placeNames,
  });

  /// Lenient: unknown or malformed fields keep their defaults.
  factory AppSettings.fromJson(Object? json) {
    if (json is! Map) return const AppSettings();
    final autoHide = json['autoHide'];
    final resolution = json['resolution'];
    final grid = json['grid'];
    return AppSettings(
      autoHideDisabled: {
        if (autoHide is Map)
          for (final kind in autoHideChoices)
            if (autoHide[kind.name] == false) kind,
      },
      addressMode: AddressDetectionMode.values.firstWhere(
        (mode) => mode.name == json['addressMode'],
        orElse: () => autoHide is Map && autoHide['address'] == false
            ? AddressDetectionMode.off
            : AddressDetectionMode.placeNames,
      ),
      resolution: CameraResolution.values.firstWhere(
        (r) => r.name == resolution,
        orElse: () => CameraResolution.fullHd,
      ),
      showGrid: grid is bool && grid,
    );
  }

  /// Kinds that are still detected and framed, but start visible. Stored as
  /// the switched-off kinds so a newly added choice starts on.
  final Set<CandidateKind> autoHideDisabled;
  final CameraResolution resolution;
  final AddressDetectionMode addressMode;

  /// Rule-of-thirds lines over the camera preview.
  final bool showGrid;

  /// Detected kinds the editor hides before the user sees the photo.
  Set<CandidateKind> get autoHideKinds => {
    if (addressMode != AddressDetectionMode.off) CandidateKind.address,
    for (final kind in autoHideChoices)
      if (!autoHideDisabled.contains(kind)) kind,
  };

  AppSettings withAutoHide(CandidateKind kind, bool hide) {
    if (kind == CandidateKind.address) {
      return copyWith(
        addressMode: hide
            ? (addressMode == AddressDetectionMode.off
                  ? AddressDetectionMode.placeNames
                  : addressMode)
            : AddressDetectionMode.off,
      );
    }
    return AppSettings(
      addressMode: addressMode,
      autoHideDisabled: hide
          ? autoHideDisabled.difference({kind})
          : autoHideDisabled.union({kind}),
      resolution: resolution,
      showGrid: showGrid,
    );
  }

  AppSettings copyWith({
    AddressDetectionMode? addressMode,
    CameraResolution? resolution,
    bool? showGrid,
  }) => AppSettings(
    addressMode: addressMode ?? this.addressMode,
    autoHideDisabled: autoHideDisabled,
    resolution: resolution ?? this.resolution,
    showGrid: showGrid ?? this.showGrid,
  );

  Map<String, Object?> toJson() => {
    'version': 2,
    'addressMode': addressMode.name,
    'autoHide': {
      for (final kind in autoHideChoices)
        kind.name: !autoHideDisabled.contains(kind),
    },
    'resolution': resolution.name,
    'grid': showGrid,
  };

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      setEquals(other.autoHideDisabled, autoHideDisabled) &&
      other.addressMode == addressMode &&
      other.resolution == resolution &&
      other.showGrid == showGrid;

  @override
  int get hashCode => Object.hash(
    addressMode,
    Object.hashAllUnordered(autoHideDisabled),
    resolution,
    showGrid,
  );
}

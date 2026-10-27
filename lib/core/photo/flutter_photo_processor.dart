import 'dart:typed_data';
import 'dart:ui' as ui;

import 'hide_region.dart';
import 'image_photo_processor.dart';
import 'photo_images.dart';
import 'photo_processing_exception.dart';
import 'photo_processor.dart';

/// Preview/analysis and editing use the same platform decoder, including EXIF
/// orientation and device JPEG variants. Only decoded pixels enter the editor;
/// export still uses the isolated, metadata-free redaction worker.
final class FlutterPhotoProcessor implements PhotoProcessor {
  FlutterPhotoProcessor({
    this.maxPixels = 24000000,
    this.maxInputBytes = 128 * 1024 * 1024,
  }) : _exporter = ImagePhotoProcessor(
         maxPixels: maxPixels,
         maxInputBytes: maxInputBytes,
       );

  final int maxPixels;
  final int maxInputBytes;
  final ImagePhotoProcessor _exporter;

  @override
  Future<SourcePhoto> normalize(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    if (bytes.length > maxInputBytes) {
      throw const PhotoProcessingException(
        PhotoProcessingFailure.imageTooLarge,
      );
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0) {
        throw const PhotoProcessingException(
          PhotoProcessingFailure.invalidImage,
        );
      }
      if (descriptor.width > maxPixels ~/ descriptor.height) {
        throw const PhotoProcessingException(
          PhotoProcessingFailure.imageTooLarge,
        );
      }
      codec = await descriptor.instantiateCodec();
      if (codec.frameCount != 1) {
        throw const PhotoProcessingException(
          PhotoProcessingFailure.unsupportedFormat,
        );
      }
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) {
          throw const PhotoProcessingException(
            PhotoProcessingFailure.encodingFailed,
          );
        }
        return SourcePhoto(
          bytes: png.buffer
              .asUint8List(png.offsetInBytes, png.lengthInBytes)
              .asUnmodifiableView(),
          width: frame.image.width,
          height: frame.image.height,
        );
      } finally {
        frame.image.dispose();
      }
    } on PhotoProcessingException {
      rethrow;
    } catch (_) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  @override
  Future<RedactedJpeg> redact(SourcePhoto photo, List<HideRegion> regions) =>
      _exporter.redact(photo, regions);
}

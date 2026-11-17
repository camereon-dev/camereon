import 'dart:typed_data';
import 'dart:ui' as ui;

/// Size Flutter itself gets when it decodes [bytes] (EXIF orientation applied),
/// the reference that the photo normalizer must match.
Future<({int width, int height})> flutterDecodedSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      return (width: frame.image.width, height: frame.image.height);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

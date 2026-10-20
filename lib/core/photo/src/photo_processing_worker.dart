import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../photo_processing_exception.dart';

typedef PixelRegion = ({int left, int top, int right, int bottom});
typedef ProcessedPixels = ({Uint8List bytes, int width, int height});

ProcessedPixels normalizePixels(Uint8List bytes, int maxPixels) {
  final decoded = _decode(bytes, maxPixels);
  // JPEG はデコード時に補正済み。PNG などで Orientation が残る場合だけ補正。
  final orientation = decoded.exif.imageIfd.orientation;
  if (orientation != null && (orientation < 1 || orientation > 8)) {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  }
  final oriented = orientation != null && orientation != 1
      ? img.bakeOrientation(decoded)
      : decoded;
  final clean = copyPixels(oriented);
  return _encode(clean, jpeg: false);
}

ProcessedPixels redactPixels(
  Uint8List bytes,
  int width,
  int height,
  List<PixelRegion> regions,
  int maxPixels,
) {
  final decoded = _decode(bytes, maxPixels, requireNormalized: true);
  if (width <= 0 ||
      height <= 0 ||
      decoded.width != width ||
      decoded.height != height ||
      (decoded.exif.imageIfd.orientation ?? 1) != 1) {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidSource);
  }
  final clean = copyPixels(decoded);
  paintRegions(clean, regions);
  return _encode(clean, jpeg: true);
}

img.Image _decode(
  Uint8List bytes,
  int maxPixels, {
  bool requireNormalized = false,
}) {
  if (bytes.isEmpty) {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  }
  final img.Decoder decoder;
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    decoder = img.JpegDecoder(maxPixels: maxPixels);
  } else if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10) {
    // IHDR の寸法を割り当て前に検査する。残りの構造は decoder で検証。
    if (bytes.length >= 24) {
      final header = ByteData.sublistView(bytes);
      _checkSize(header.getUint32(16), header.getUint32(20), maxPixels);
    }
    decoder = img.PngDecoder(maxPixels: maxPixels);
  } else {
    throw const PhotoProcessingException(
      PhotoProcessingFailure.unsupportedFormat,
    );
  }
  try {
    // JPEG デコーダーは Orientation を補正して消すため、補正前に検査する。
    final exif = decoder is img.JpegDecoder
        ? _jpegExif(bytes)
        : _pngExif(bytes);
    final orientation = exif.imageIfd.orientation ?? 1;
    if (orientation < 1 || orientation > 8) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    if (requireNormalized && orientation != 1) {
      throw const PhotoProcessingException(
        PhotoProcessingFailure.invalidSource,
      );
    }
    final info = decoder.startDecode(bytes);
    if (info == null) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    _checkSize(info.width, info.height, maxPixels);
    if (info.numFrames != 1 || (info is img.PngInfo && info.isAnimated)) {
      throw const PhotoProcessingException(
        PhotoProcessingFailure.unsupportedFormat,
      );
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    if (decoder is img.PngDecoder) {
      // image 4.12.0 は PNG の eXIf を解釈しないため TIFF 部分を明示的に読む。
      decoded.exif = exif;
    }
    return decoded;
  } on img.ImageException {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  } on RangeError {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  }
}

// スキャンデータには入らず、APP1 の EXIF だけを読む。
img.ExifData _jpegExif(Uint8List bytes) {
  var offset = 2;
  img.ExifData? exif;
  while (offset < bytes.length) {
    if (bytes[offset++] != 0xff) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xda || marker == 0xd9) break;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) break;
    final size = (bytes[offset] << 8) | bytes[offset + 1];
    if (size < 2 || offset + size > bytes.length) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    if (marker == 0xe1 &&
        size >= 8 &&
        String.fromCharCodes(bytes.sublist(offset + 2, offset + 8)) ==
            'Exif\x00\x00') {
      if (exif != null) {
        throw const PhotoProcessingException(
          PhotoProcessingFailure.invalidImage,
        );
      }
      exif = _readExif(Uint8List.sublistView(bytes, offset + 8, offset + size));
    }
    offset += size;
  }
  return exif ?? img.ExifData();
}

img.ExifData _readExif(Uint8List tiff) {
  if (tiff.length < 8) {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  }
  final signature = ByteData.sublistView(tiff).getUint32(0);
  if (signature != 0x49492a00 && signature != 0x4d4d002a) {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  }
  return img.ExifData.fromInputBuffer(img.InputBuffer(tiff));
}

img.ExifData _pngExif(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var offset = 8;
  img.ExifData? exif;
  while (offset + 12 <= bytes.length) {
    final size = data.getUint32(offset);
    final end = offset + 12 + size;
    if (end > bytes.length) {
      throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
    }
    if (data.getUint32(offset + 4) == 0x65584966) {
      if (exif != null || size < 8) {
        throw const PhotoProcessingException(
          PhotoProcessingFailure.invalidImage,
        );
      }
      final tiff = Uint8List.sublistView(bytes, offset + 8, end - 4);
      // ExifData.read の戻り値には依存せず TIFF ヘッダーを検査する。
      exif = _readExif(tiff);
    }
    if (data.getUint32(offset + 4) == 0x49454e44) break;
    offset = end;
  }
  return exif ?? img.ExifData();
}

void _checkSize(int width, int height, int maxPixels) {
  if (width <= 0 || height <= 0) {
    throw const PhotoProcessingException(PhotoProcessingFailure.invalidImage);
  }
  if (width > maxPixels ~/ height) {
    throw const PhotoProcessingException(PhotoProcessingFailure.imageTooLarge);
  }
}

/// メタデータ・付加画像はコピーしない。透過 PNG は白へ合成して RGB にする。
img.Image copyPixels(img.Image source) {
  final clean = img.Image(width: source.width, height: source.height);
  for (final pixel in source) {
    final alpha = pixel.aNormalized;
    clean.setPixelRgb(
      pixel.x,
      pixel.y,
      (pixel.rNormalized * alpha * 255 + 255 * (1 - alpha)).round(),
      (pixel.gNormalized * alpha * 255 + 255 * (1 - alpha)).round(),
      (pixel.bNormalized * alpha * 255 + 255 * (1 - alpha)).round(),
    );
  }
  return clean;
}

/// 半開区間を、終点を含む fillRect の引数に変換する。
void paintRegions(img.Image image, List<PixelRegion> regions) {
  for (final r in regions) {
    if (r.left < 0 ||
        r.top < 0 ||
        r.right > image.width ||
        r.bottom > image.height ||
        r.left >= r.right ||
        r.top >= r.bottom) {
      throw const PhotoProcessingException(
        PhotoProcessingFailure.invalidRegion,
      );
    }
  }
  for (final r in regions) {
    img.fillRect(
      image,
      x1: r.left,
      y1: r.top,
      x2: r.right - 1,
      y2: r.bottom - 1,
      color: img.ColorRgb8(0, 0, 0),
      alphaBlend: false,
    );
  }
}

ProcessedPixels _encode(img.Image image, {required bool jpeg}) {
  try {
    final bytes = jpeg
        ? img.encodeJpg(image, quality: 100, chroma: img.JpegChroma.yuv444)
        : img.encodePng(image);
    return (bytes: bytes, width: image.width, height: image.height);
  } catch (_) {
    throw const PhotoProcessingException(PhotoProcessingFailure.encodingFailed);
  }
}

import 'dart:typed_data';

import 'package:image/image.dart' as img;

// 個人情報を含まない人工画像。期待する向きはテスト側の固定表で検査する。
img.Image colorGrid() {
  final image = img.Image(width: 48, height: 32);
  final colors = [
    img.ColorRgb8(240, 20, 20),
    img.ColorRgb8(20, 240, 20),
    img.ColorRgb8(20, 20, 240),
    img.ColorRgb8(240, 240, 20),
    img.ColorRgb8(240, 20, 240),
    img.ColorRgb8(20, 240, 240),
  ];
  for (final p in image) {
    p.set(colors[(p.y ~/ 16) * 3 + p.x ~/ 16]);
  }
  return image;
}

Uint8List metadataJpeg({int orientation = 1}) {
  final image = colorGrid();
  image.exif.imageIfd
    ..orientation = orientation
    ..make = 'FICTIONAL-CAMERA';
  image.exif.exifIfd[0x9003] = img.IfdValueAscii('2000:01:02 03:04:05');
  image.exif.gpsIfd
    ..gpsLatitude = 12
    ..gpsLongitude = 34;
  image.exif.thumbnailIfd[0x0103] = img.IfdValueShort(6);
  image.exif.thumbnailData = img.encodeJpg(colorGrid());
  final jpeg = img.encodeJpg(image);
  // 元の JPEG にしかない XMP / IPTC / コメント / JFXX / 末尾付加データ。
  return Uint8List.fromList([
    ...jpeg.take(2),
    ...segment(0xe1, 'http://ns.adobe.com/xap/1.0/\x00FICTIONAL-XMP'.codeUnits),
    ...segment(0xed, 'Photoshop 3.0\x00FICTIONAL-IPTC'.codeUnits),
    ...segment(0xfe, 'FICTIONAL-COMMENT'.codeUnits),
    ...segment(0xe0, [
      ...'JFXX\x00'.codeUnits,
      0x10,
      ...img.encodeJpg(colorGrid()),
    ]),
    ...jpeg.skip(2),
    ...'FICTIONAL-TRAILER'.codeUnits,
  ]);
}

List<int> segment(int marker, List<int> bytes) {
  final size = bytes.length + 2;
  return [255, marker, size >> 8, size & 255, ...bytes];
}

Uint8List orientedPng(int orientation) {
  final exif = img.ExifData();
  exif.imageIfd.orientation = orientation;
  final buffer = img.OutputBuffer();
  exif.write(buffer);
  final payload = buffer.getBytes();
  final chunk = [...'eXIf'.codeUnits, ...payload];
  var crc = 0xffffffff;
  for (final byte in chunk) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
  }
  crc ^= 0xffffffff;
  final sizeBytes = ByteData(4)..setUint32(0, payload.length);
  final crcBytes = ByteData(4)..setUint32(0, crc);
  final png = img.encodePng(colorGrid());
  // PNG signature + IHDR の直後へ、仕様どおり TIFF を持つ eXIf を挿入。
  return Uint8List.fromList([
    ...png.take(33),
    ...sizeBytes.buffer.asUint8List(),
    ...chunk,
    ...crcBytes.buffer.asUint8List(),
    ...png.skip(33),
  ]);
}

/// JPEG 構造を image パッケージに依存せず読む。スキャン中の FF00 を区別する。
List<({int marker, List<int> data})> jpegSegments(Uint8List bytes) {
  if (bytes[0] != 255 || bytes[1] != 0xd8) {
    throw const FormatException('Missing SOI');
  }
  final result = <({int marker, List<int> data})>[];
  var offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset++] != 255) throw const FormatException('Missing marker');
    while (bytes[offset] == 255) {
      offset++;
    }
    final marker = bytes[offset++];
    if (marker == 0xd9) {
      if (offset != bytes.length) throw const FormatException('Trailing data');
      return result;
    }
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) {
      throw const FormatException('Invalid segment');
    }
    result.add((
      marker: marker,
      data: bytes.sublist(offset + 2, offset + length),
    ));
    offset += length;
    if (marker == 0xda) {
      while (offset < bytes.length) {
        if (bytes[offset] != 255) {
          offset++;
        } else if (bytes[offset + 1] == 0 ||
            (bytes[offset + 1] >= 0xd0 && bytes[offset + 1] <= 0xd7)) {
          offset += 2;
        } else {
          break;
        }
      }
    }
  }
  throw const FormatException('Missing EOI');
}

List<String> pngChunks(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final names = <String>[];
  var offset = 8;
  while (offset < bytes.length) {
    final size = data.getUint32(offset);
    names.add(String.fromCharCodes(bytes.sublist(offset + 4, offset + 8)));
    offset += size + 12;
  }
  if (offset != bytes.length || names.last != 'IEND') {
    throw const FormatException('Invalid PNG');
  }
  return names;
}

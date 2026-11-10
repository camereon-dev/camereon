import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'hide_region.dart';
import 'image_photo_processor.dart';
import 'photo_images.dart';
import 'src/frosted_fill.dart';

/// 編集画面に重ねる、1 つの範囲のすりガラスの塗り。
///
/// [bounds] は元画像の座標で、[image] はその範囲を表示用解像度で描いたもの。
/// 形と縁の外側は透明なので、重なる範囲の塗りを何枚重ねても元の写真を
/// 描き戻さない。一度作れば写真の拡大・移動で描き直す必要はない。
class FrostedPatch {
  const FrostedPatch(this.region, this.bounds, this.image);
  final HideRegion region;
  final ui.Rect bounds;
  final ui.Image image;
  void dispose() => image.dispose();
}

/// 保存前の表示に使う、範囲ごとのすりガラス生成。
///
/// 保存時の `PhotoProcessor.redact` と同じ塗りの計算を、表示用に縮小した
/// 画素へ適用する。計算は isolate で行い、画面の描画は結果の画像を置くだけ。
abstract interface class FrostedPreviewer {
  /// 元写真を表示用解像度に展開する。失敗しても例外にせず、以後の
  /// [patch] は null を返す。
  Future<void> load(SourcePhoto photo);

  /// [region] の塗り。準備ができていなければ null。
  Future<FrostedPatch?> patch(HideRegion region);

  void dispose();

  factory FrostedPreviewer({int maxSide}) = IsolateFrostedPreviewer;

  /// 表示を作らない（テストや省電力の代替）。
  const factory FrostedPreviewer.none() = _NoFrostedPreviewer;
}

class _NoFrostedPreviewer implements FrostedPreviewer {
  const _NoFrostedPreviewer();
  @override
  Future<void> load(SourcePhoto photo) async {}
  @override
  Future<FrostedPatch?> patch(HideRegion region) async => null;
  @override
  void dispose() {}
}

class IsolateFrostedPreviewer implements FrostedPreviewer {
  IsolateFrostedPreviewer({this.maxSide = 2048});

  /// 表示用の長辺。塗りは滑らかなので元解像度は要らない。
  final int maxSide;
  Uint8List? _pixels;
  int _width = 0;
  int _height = 0;
  int _sourceWidth = 0;
  int _sourceHeight = 0;
  bool _disposed = false;

  @override
  Future<void> load(SourcePhoto photo) async {
    _pixels = null;
    try {
      final longest = photo.width > photo.height ? photo.width : photo.height;
      final scale = longest > maxSide ? maxSide / longest : 1.0;
      final codec = await ui.instantiateImageCodec(
        photo.bytes,
        targetWidth: (photo.width * scale).round().clamp(1, maxSide),
        targetHeight: (photo.height * scale).round().clamp(1, maxSide),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (data == null || _disposed) return;
          _pixels = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          _width = frame.image.width;
          _height = frame.image.height;
          _sourceWidth = photo.width;
          _sourceHeight = photo.height;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      _pixels = null;
    }
  }

  @override
  Future<FrostedPatch?> patch(HideRegion region) async {
    final pixels = _pixels;
    if (pixels == null || _disposed) return null;
    final sx = _width / _sourceWidth;
    final sy = _height / _sourceHeight;
    final source = pixelShape(region);
    final shape = (
      left: (source.left * sx).floor().clamp(0, _width - 1),
      top: (source.top * sy).floor().clamp(0, _height - 1),
      right: (source.right * sx).ceil().clamp(1, _width),
      bottom: (source.bottom * sy).ceil().clamp(1, _height),
      shape: source.shape,
      points: Float64List.fromList([
        for (var i = 0; i < source.points.length; i += 2) ...[
          source.points[i] * sx,
          source.points[i + 1] * sy,
        ],
      ]),
    );
    if (shape.left >= shape.right || shape.top >= shape.bottom) return null;
    final window = frostWindow(shape, _width, _height);
    final w = window.right - window.left;
    final h = window.bottom - window.top;
    if (w <= 0 || h <= 0) return null;
    // 必要な窓の画素だけを isolate へ渡す。写真全体は送らない。
    final crop = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final from = ((window.top + y) * _width + window.left) * 4;
      crop.setRange(y * w * 4, (y + 1) * w * 4, pixels, from);
    }
    final local = (
      left: shape.left - window.left,
      top: shape.top - window.top,
      right: shape.right - window.left,
      bottom: shape.bottom - window.top,
      shape: shape.shape,
      points: Float64List.fromList([
        for (var i = 0; i < shape.points.length; i += 2) ...[
          shape.points[i] - window.left,
          shape.points[i + 1] - window.top,
        ],
      ]),
    );
    // Only the shape and its feather are opaque in the result; the rest of
    // the window is transparent so stacked patches never repaint originals.
    final ({Uint8List rgba, int left, int top, int width, int height})? layer;
    try {
      layer = await Isolate.run(
        () => frostOverlay(crop, w, h, 4, local),
        debugName: 'frosted-preview',
      );
    } catch (_) {
      return null;
    }
    if (layer == null || _disposed) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      layer.rgba,
      layer.width,
      layer.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    if (_disposed) {
      image.dispose();
      return null;
    }
    final x = window.left + layer.left;
    final y = window.top + layer.top;
    return FrostedPatch(
      region,
      ui.Rect.fromLTRB(
        x / sx,
        y / sy,
        (x + layer.width) / sx,
        (y + layer.height) / sy,
      ),
      image,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _pixels = null;
  }

  @visibleForTesting
  bool get isLoaded => _pixels != null;
}

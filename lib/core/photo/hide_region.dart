import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// 隠す範囲の形。[HideRegion] の整数の外接矩形に加えて、楕円や多角形で
/// 検出した形に沿って隠せる。
enum HideShape { rectangle, ellipse, polygon }

/// 隠す範囲。[SourcePhoto] の画素座標（向きを正規化した後）で表す。
///
/// 端は画素単位の整数で持ち、`right`・`bottom` は範囲に含まない。
/// [shape] が楕円なら外接矩形に内接する楕円、多角形なら [points] の内側を隠す。
/// 画面上の座標からの変換は編集画面が担当し、[HideRegion.fromRect] 等で作る。
@immutable
class HideRegion {
  const HideRegion._(
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.shape,
    this.points,
  );

  /// [rect] を画像の範囲に収め、隠し漏れがないよう外側へ丸めて作る。
  ///
  /// 逆向きにドラッグした長方形も受け付ける。画像と重ならない場合や、
  /// 幅・高さが 0 になる場合は null を返す。
  static HideRegion? fromRect(
    Rect rect, {
    required int imageWidth,
    required int imageHeight,
  }) => _bounded(rect, imageWidth, imageHeight, HideShape.rectangle, const []);

  /// [rect] に内接する楕円。顔のように角のない形へ使う。
  static HideRegion? ellipse(
    Rect rect, {
    required int imageWidth,
    required int imageHeight,
  }) => _bounded(rect, imageWidth, imageHeight, HideShape.ellipse, const []);

  /// 画像座標の頂点列で囲む多角形。文字の傾きや人物の輪郭に沿う。
  /// 頂点は画像の内側へ寄せ、外接矩形は外側へ丸める。3点未満や潰れた形は null。
  static HideRegion? polygon(
    List<Offset> points, {
    required int imageWidth,
    required int imageHeight,
  }) {
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        points.length < 3 ||
        points.any((p) => !p.dx.isFinite || !p.dy.isFinite)) {
      return null;
    }
    final clamped = List<Offset>.unmodifiable([
      for (final p in points)
        Offset(
          p.dx.clamp(0, imageWidth).toDouble(),
          p.dy.clamp(0, imageHeight).toDouble(),
        ),
    ]);
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in clamped) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return _bounded(
      Rect.fromLTRB(minX, minY, maxX, maxY),
      imageWidth,
      imageHeight,
      HideShape.polygon,
      clamped,
    );
  }

  static HideRegion? _bounded(
    Rect rect,
    int imageWidth,
    int imageHeight,
    HideShape shape,
    List<Offset> points,
  ) {
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        !rect.left.isFinite ||
        !rect.top.isFinite ||
        !rect.right.isFinite ||
        !rect.bottom.isFinite ||
        rect.left == rect.right ||
        rect.top == rect.bottom) {
      return null;
    }
    final left = (rect.left < rect.right ? rect.left : rect.right).floor();
    final right = (rect.left < rect.right ? rect.right : rect.left).ceil();
    final top = (rect.top < rect.bottom ? rect.top : rect.bottom).floor();
    final bottom = (rect.top < rect.bottom ? rect.bottom : rect.top).ceil();

    final region = HideRegion._(
      left.clamp(0, imageWidth),
      top.clamp(0, imageHeight),
      right.clamp(0, imageWidth),
      bottom.clamp(0, imageHeight),
      shape,
      points,
    );
    return region.width > 0 && region.height > 0 ? region : null;
  }

  final int left;
  final int top;
  final int right;
  final int bottom;
  final HideShape shape;

  /// 多角形の頂点（画像座標）。長方形・楕円では空。
  final List<Offset> points;

  int get width => right - left;
  int get height => bottom - top;

  Rect toRect() => Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );

  /// 画像座標での形。表示と当たり判定に使う。
  Path toPath() {
    final path = Path();
    switch (shape) {
      case HideShape.rectangle:
        path.addRect(toRect());
      case HideShape.ellipse:
        path.addOval(toRect());
      case HideShape.polygon:
        path.addPolygon(points, true);
    }
    return path;
  }

  /// [point] が形の内側にあるか。外接矩形ではなく形そのもので判定する。
  bool contains(Offset point) {
    if (!toRect().contains(point)) return false;
    switch (shape) {
      case HideShape.rectangle:
        return true;
      case HideShape.ellipse:
        final rect = toRect();
        final dx = (point.dx - rect.center.dx) / (rect.width / 2);
        final dy = (point.dy - rect.center.dy) / (rect.height / 2);
        return dx * dx + dy * dy <= 1;
      case HideShape.polygon:
        var inside = false;
        for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
          final a = points[i];
          final b = points[j];
          if ((a.dy > point.dy) != (b.dy > point.dy) &&
              point.dx <
                  (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
            inside = !inside;
          }
        }
        return inside;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HideRegion &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.shape == shape &&
      listEquals(other.points, points);

  @override
  int get hashCode =>
      Object.hash(left, top, right, bottom, shape, Object.hashAll(points));

  @override
  String toString() =>
      'HideRegion($left, $top, $right, $bottom, ${shape.name}'
      '${shape == HideShape.polygon ? ', ${points.length} points' : ''})';
}

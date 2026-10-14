import 'dart:ui';

import 'package:flutter/foundation.dart';

/// 黒塗りする範囲。[SourcePhoto] の画素座標（向きを正規化した後）で表す。
///
/// 端は画素単位の整数で持ち、`right`・`bottom` は範囲に含まない。
/// 画面上の座標からの変換は編集画面が担当し、[HideRegion.fromRect] で作る。
@immutable
class HideRegion {
  const HideRegion._(this.left, this.top, this.right, this.bottom);

  /// [rect] を画像の範囲に収め、隠し漏れがないよう外側へ丸めて作る。
  ///
  /// 逆向きにドラッグした長方形も受け付ける。画像と重ならない場合や、
  /// 幅・高さが 0 になる場合は null を返す。
  static HideRegion? fromRect(
    Rect rect, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final left = (rect.left < rect.right ? rect.left : rect.right).floor();
    final right = (rect.left < rect.right ? rect.right : rect.left).ceil();
    final top = (rect.top < rect.bottom ? rect.top : rect.bottom).floor();
    final bottom = (rect.top < rect.bottom ? rect.bottom : rect.top).ceil();

    final region = HideRegion._(
      left.clamp(0, imageWidth),
      top.clamp(0, imageHeight),
      right.clamp(0, imageWidth),
      bottom.clamp(0, imageHeight),
    );
    return region.width > 0 && region.height > 0 ? region : null;
  }

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;

  Rect toRect() => Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );

  @override
  bool operator ==(Object other) =>
      other is HideRegion &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'HideRegion($left, $top, $right, $bottom)';
}

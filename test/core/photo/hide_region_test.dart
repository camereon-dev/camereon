import 'dart:ui';

import 'package:camereon/core/photo/hide_region.dart';
import 'package:flutter_test/flutter_test.dart';

HideRegion? region(Rect rect) =>
    HideRegion.fromRect(rect, imageWidth: 400, imageHeight: 300);

void main() {
  test('画素の端に揃っていない長方形は外側へ丸める', () {
    expect(
      region(const Rect.fromLTRB(10.6, 20.2, 30.1, 40.9)),
      region(const Rect.fromLTRB(10, 20, 31, 41)),
    );
    expect(region(const Rect.fromLTRB(10.6, 20.2, 30.1, 40.9))!.width, 21);
  });

  test('逆向きにドラッグした長方形も同じ範囲になる', () {
    expect(
      region(const Rect.fromLTRB(30, 40, 10, 20)),
      region(const Rect.fromLTRB(10, 20, 30, 40)),
    );
  });

  test('画像からはみ出した部分は切り取る', () {
    final clamped = region(const Rect.fromLTRB(-20, -5, 450, 320))!;

    expect(clamped.toRect(), const Rect.fromLTRB(0, 0, 400, 300));
  });

  test('画像と重ならない・大きさがない長方形は作らない', () {
    expect(region(const Rect.fromLTRB(410, 10, 500, 50)), isNull);
    expect(region(const Rect.fromLTRB(10, 10, 10, 50)), isNull);
  });

  test('幅や高さが0の小数座標を丸めて1画素の範囲にしない', () {
    expect(region(const Rect.fromLTRB(10.5, 20.2, 10.5, 40.9)), isNull);
    expect(region(const Rect.fromLTRB(10.5, 20.2, 30.1, 20.2)), isNull);
  });

  test('非有限座標と不正な画像サイズは範囲を作らない', () {
    expect(region(const Rect.fromLTRB(double.nan, 0, 20, 20)), isNull);
    expect(region(const Rect.fromLTRB(0, 0, double.infinity, 20)), isNull);
    for (final size in [(0, 10), (10, 0), (-1, 10), (10, -1)]) {
      expect(
        HideRegion.fromRect(
          const Rect.fromLTRB(0, 0, 5, 5),
          imageWidth: size.$1,
          imageHeight: size.$2,
        ),
        isNull,
      );
    }
  });
}

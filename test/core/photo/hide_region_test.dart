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
}

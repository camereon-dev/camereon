import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// 8ビットのマスク（0〜255、[width]×[height]）から外周の多角形を取り出す。
///
/// セルの中心を格子点とみなし、しきい値との交点を線形補間で求める
/// marching squares で等高線を作る。複数の輪郭があれば面積が最大のものを
/// 返し、座標はマスクのセル単位（0..width, 0..height）。輪郭がなければ null。
/// 頂点は [tolerance] セルの誤差で間引く。
List<Offset>? traceMask(
  Uint8List mask,
  int width,
  int height, {
  int threshold = 128,
  double tolerance = .35,
}) {
  if (width <= 0 || height <= 0 || mask.length < width * height) return null;
  // 周囲に 1 セルの「外側」を足し、縁に接する形も閉じた輪郭にする。
  final w = width + 2;
  final h = height + 2;
  double value(int x, int y) {
    if (x <= 0 || y <= 0 || x > width || y > height) return 0;
    return mask[(y - 1) * width + (x - 1)].toDouble();
  }

  // 各セル（4格子点）の辺ごとの交点を線分として集める。
  final segments = <(Offset, Offset)>[];
  for (var y = 0; y < h - 1; y++) {
    for (var x = 0; x < w - 1; x++) {
      final tl = value(x, y), tr = value(x + 1, y);
      final bl = value(x, y + 1), br = value(x + 1, y + 1);
      var code = 0;
      if (tl >= threshold) code |= 8;
      if (tr >= threshold) code |= 4;
      if (br >= threshold) code |= 2;
      if (bl >= threshold) code |= 1;
      if (code == 0 || code == 15) continue;
      Offset lerp(
        double ax,
        double ay,
        double a,
        double bx,
        double by,
        double b,
      ) {
        final t = ((threshold - a) / (b - a)).clamp(0.0, 1.0);
        return Offset(ax + (bx - ax) * t, ay + (by - ay) * t);
      }

      // 格子点座標は「セル中心」なので、マスク座標では x - .5 になる。
      final gx = x - .5, gy = y - .5;
      final top = lerp(gx, gy, tl, gx + 1, gy, tr);
      final right = lerp(gx + 1, gy, tr, gx + 1, gy + 1, br);
      final bottom = lerp(gx, gy + 1, bl, gx + 1, gy + 1, br);
      final left = lerp(gx, gy, tl, gx, gy + 1, bl);
      switch (code) {
        case 1 || 14:
          segments.add((left, bottom));
        case 2 || 13:
          segments.add((bottom, right));
        case 3 || 12:
          segments.add((left, right));
        case 4 || 11:
          segments.add((top, right));
        case 6 || 9:
          segments.add((top, bottom));
        case 7 || 8:
          segments.add((left, top));
        case 5:
          segments.add((left, top));
          segments.add((bottom, right));
        case 10:
          segments.add((top, right));
          segments.add((left, bottom));
      }
    }
  }
  if (segments.isEmpty) return null;
  // 端点を量子化して線分をつなぎ、閉じた輪郭にする。
  String key(Offset p) => '${(p.dx * 64).round()},${(p.dy * 64).round()}';
  final byStart = <String, List<int>>{};
  for (var i = 0; i < segments.length; i++) {
    byStart.putIfAbsent(key(segments[i].$1), () => []).add(i);
    byStart.putIfAbsent(key(segments[i].$2), () => []).add(i);
  }
  final used = List<bool>.filled(segments.length, false);
  List<Offset>? best;
  var bestArea = 0.0;
  for (var start = 0; start < segments.length; start++) {
    if (used[start]) continue;
    used[start] = true;
    final loop = <Offset>[segments[start].$1, segments[start].$2];
    var current = segments[start].$2;
    while (true) {
      final candidates = byStart[key(current)];
      int? next;
      if (candidates != null) {
        for (final c in candidates) {
          if (!used[c]) {
            next = c;
            break;
          }
        }
      }
      if (next == null) break;
      used[next] = true;
      final s = segments[next];
      current = key(s.$1) == key(current) ? s.$2 : s.$1;
      if (key(current) == key(loop.first)) break;
      loop.add(current);
    }
    if (loop.length < 3) continue;
    final area = _area(loop).abs();
    if (area > bestArea) {
      bestArea = area;
      best = loop;
    }
  }
  if (best == null || bestArea == 0) return null;
  final simplified = _simplify(best, tolerance);
  return simplified.length >= 3 ? simplified : best;
}

double _area(List<Offset> polygon) {
  var sum = 0.0;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    sum += polygon[j].dx * polygon[i].dy - polygon[i].dx * polygon[j].dy;
  }
  return sum / 2;
}

/// Ramer–Douglas–Peucker。閉じた輪郭は最遠点で二つの開いた列に分けて間引く。
List<Offset> _simplify(List<Offset> loop, double tolerance) {
  if (loop.length < 5) return loop;
  var far = 0;
  var distance = 0.0;
  for (var i = 1; i < loop.length; i++) {
    final d = (loop[i] - loop[0]).distanceSquared;
    if (d > distance) {
      distance = d;
      far = i;
    }
  }
  final a = _rdp(loop.sublist(0, far + 1), tolerance);
  final b = _rdp([...loop.sublist(far), loop[0]], tolerance);
  return [...a, ...b.sublist(1, b.length - 1)];
}

List<Offset> _rdp(List<Offset> points, double tolerance) {
  if (points.length < 3) return points;
  final a = points.first, b = points.last;
  var index = 0;
  var worst = 0.0;
  for (var i = 1; i < points.length - 1; i++) {
    final d = _distance(points[i], a, b);
    if (d > worst) {
      worst = d;
      index = i;
    }
  }
  if (worst <= tolerance) return [a, b];
  final left = _rdp(points.sublist(0, index + 1), tolerance);
  final right = _rdp(points.sublist(index), tolerance);
  return [...left, ...right.sublist(1)];
}

double _distance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final length = ab.distance;
  if (length == 0) return (p - a).distance;
  return ((ab.dx) * (a.dy - p.dy) - (a.dx - p.dx) * (ab.dy)).abs() / length;
}

/// マスク座標（セル単位）の輪郭を [bounds] の矩形へ写す。
List<Offset> mapOutline(
  List<Offset> outline,
  int width,
  int height,
  Rect bounds,
) {
  final sx = bounds.width / width;
  final sy = bounds.height / height;
  return [
    for (final p in outline)
      Offset(bounds.left + p.dx * sx, bounds.top + p.dy * sy),
  ];
}

/// マスクの明るいセルの割合。空のマスクや細すぎる断片を捨てる判断に使う。
double maskCoverage(
  Uint8List mask,
  int width,
  int height, {
  int threshold = 128,
}) {
  var count = 0;
  final n = math.min(mask.length, width * height);
  for (var i = 0; i < n; i++) {
    if (mask[i] >= threshold) count++;
  }
  return n == 0 ? 0 : count / n;
}

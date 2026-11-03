import 'dart:math' as math;
import 'dart:typed_data';

/// 隠す形を isolate へ送れる形にしたもの。座標は処理する画像の画素。
/// shape: 0 長方形、1 楕円、2 多角形（points は x, y の繰り返し）。
typedef PixelShape = ({
  int left,
  int top,
  int right,
  int bottom,
  int shape,
  Float64List points,
});

/// 周囲の画素だけから作った「すりガラス」の塗りで形の内側を置き換える。
///
/// 内側の画素は一切参照しない（内容は捨てる）ので黒塗りと同じく復元できない。
/// 塗りは形の外側の色を大きくぼかしたもので、縁は外側へ向けて数画素だけ
/// なじませる。質感が平坦になりすぎないよう、周囲の色のばらつきに応じた
/// 弱いノイズを決定的に加える。[channels] は 3（RGB）か 4（RGBA）。
void frostShapes(
  Uint8List pixels,
  int width,
  int height,
  int channels,
  List<PixelShape> shapes,
) {
  if (shapes.isEmpty) return;
  // Exclude the union before any region is painted. Otherwise an earlier
  // region can sample private pixels in a neighbouring, not-yet-painted one.
  final excluded = Uint8List(width * height);
  for (final shape in shapes) {
    final left = math.max(0, shape.left);
    final top = math.max(0, shape.top);
    final right = math.min(width, shape.right);
    final bottom = math.min(height, shape.bottom);
    final w = right - left, h = bottom - top;
    if (w <= 0 || h <= 0) continue;
    final mask = rasterize(shape, left, top, w, h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] != 0) excluded[(top + y) * width + left + x] = 1;
      }
    }
  }
  for (final shape in shapes) {
    _frost(pixels, width, height, channels, shape, excluded);
  }
}

/// 形の内側の画素を 1 に。[left]/[top] は出力マスクの原点、[w]/[h] はその大きさ。
Uint8List rasterize(PixelShape shape, int left, int top, int w, int h) {
  final mask = Uint8List(w * h);
  final l = math.max(shape.left, left);
  final t = math.max(shape.top, top);
  final r = math.min(shape.right, left + w);
  final b = math.min(shape.bottom, top + h);
  if (l >= r || t >= b) return mask;
  switch (shape.shape) {
    case 0:
      for (var y = t; y < b; y++) {
        mask.fillRange(
          (y - top) * w + (l - left),
          (y - top) * w + (r - left),
          1,
        );
      }
    case 1:
      final cx = (shape.left + shape.right) / 2;
      final cy = (shape.top + shape.bottom) / 2;
      final rx = (shape.right - shape.left) / 2;
      final ry = (shape.bottom - shape.top) / 2;
      for (var y = t; y < b; y++) {
        final dy = (y + .5 - cy) / ry;
        final span = 1 - dy * dy;
        if (span <= 0) continue;
        final half = rx * math.sqrt(span);
        final from = math.max(l, (cx - half).ceil());
        final to = math.min(r, (cx + half).floor());
        if (from < to) {
          mask.fillRange(
            (y - top) * w + (from - left),
            (y - top) * w + (to - left),
            1,
          );
        }
      }
    default:
      final n = shape.points.length ~/ 2;
      final crossings = <double>[];
      for (var y = t; y < b; y++) {
        final sy = y + .5;
        crossings.clear();
        for (var i = 0, j = n - 1; i < n; j = i++) {
          final ax = shape.points[2 * i], ay = shape.points[2 * i + 1];
          final bx = shape.points[2 * j], by = shape.points[2 * j + 1];
          if ((ay > sy) != (by > sy)) {
            crossings.add(ax + (sy - ay) * (bx - ax) / (by - ay));
          }
        }
        crossings.sort();
        for (var k = 0; k + 1 < crossings.length; k += 2) {
          final from = math.max(l, (crossings[k] - .5).ceil());
          final to = math.min(r, (crossings[k + 1] - .5).ceil());
          if (from < to) {
            mask.fillRange(
              (y - top) * w + (from - left),
              (y - top) * w + (to - left),
              1,
            );
          }
        }
      }
  }
  return mask;
}

/// 縁のなじませ幅。形の短辺の 8%、2〜24 画素。
double featherOf(PixelShape s) =>
    (math.min(s.right - s.left, s.bottom - s.top) * .08)
        .clamp(2.0, 24.0)
        .toDouble();

/// 塗りを作る周囲の広さ。形の短辺の半分より大きければ、どの内側の画素からも
/// 外側の色が届く（内接円の半径は短辺の半分以下）。長辺に合わせないことで、
/// 細長い文字行は離れた色を混ぜず、すぐ隣の背景の色になる。
double reachOf(PixelShape s) =>
    (math.min(s.right - s.left, s.bottom - s.top) / 2 + featherOf(s) * 2)
        .clamp(6.0, 4096.0)
        .toDouble();

/// [frostShapes] が形の周りで読み書きする画素の範囲（画像内に切り詰め済み）。
({int left, int top, int right, int bottom}) frostWindow(
  PixelShape s,
  int width,
  int height,
) {
  final int pad = (reachOf(s) + featherOf(s)).ceil();
  return (
    left: math.max(0, s.left - pad),
    top: math.max(0, s.top - pad),
    right: math.min(width, s.right + pad),
    bottom: math.min(height, s.bottom + pad),
  );
}

void _frost(
  Uint8List px,
  int width,
  int height,
  int channels,
  PixelShape s,
  Uint8List excluded,
) {
  final double feather = featherOf(s);
  final double reach = reachOf(s);
  final window = frostWindow(s, width, height);
  final int left = window.left;
  final int top = window.top;
  final int w = window.right - left;
  final int h = window.bottom - top;
  if (w <= 0 || h <= 0) return;
  // Only the shape plus its feather band is ever written. The wider window
  // is read-only: it supplies the surrounding colours.
  final int band = feather.ceil() + 1;
  final int bandLeft = math.max(left, s.left - band);
  final int bandTop = math.max(top, s.top - band);
  final int bandRight = math.min(window.right, s.right + band);
  final int bandBottom = math.min(window.bottom, s.bottom + band);
  final int bw = bandRight - bandLeft;
  final int bh = bandBottom - bandTop;
  if (bw <= 0 || bh <= 0) return;
  final inside = rasterize(s, bandLeft, bandTop, bw, bh);

  // 塗りの色場は縮小した格子で作る。大きくぼかすので解像度は要らない。
  // 窓が大きいときは画素も間引いて集計する。
  final double scale = math.min(1.0, 384 / math.max(w, h));
  final int gw = math.max(1, (w * scale).ceil());
  final int gh = math.max(1, (h * scale).ceil());
  final int step = math.max(1, (1 / scale).floor());
  final sums = Float64List(gw * gh * 3);
  final squares = Float64List(gw * gh);
  final weights = Float64List(gw * gh);
  for (var y = 0; y < h; y += step) {
    final int gy = math.min(gh - 1, (y * scale).floor());
    for (var x = 0; x < w; x += step) {
      if (excluded[(top + y) * width + left + x] != 0) {
        continue;
      }
      final int gi = gy * gw + math.min(gw - 1, (x * scale).floor());
      final int p = ((top + y) * width + left + x) * channels;
      final r = px[p].toDouble(),
          g = px[p + 1].toDouble(),
          b = px[p + 2].toDouble();
      sums[gi * 3] += r;
      sums[gi * 3 + 1] += g;
      sums[gi * 3 + 2] += b;
      final luma = .299 * r + .587 * g + .114 * b;
      squares[gi] += luma * luma;
      weights[gi] += 1;
    }
  }
  var total = 0.0;
  for (final v in weights) {
    total += v;
  }
  final int radius = math.max(1, (reach * scale).round());
  for (var pass = 0; pass < 3; pass++) {
    _boxBlur(sums, gw, gh, 3, radius);
    _boxBlur(squares, gw, gh, 1, radius);
    _boxBlur(weights, gw, gh, 1, radius);
  }
  // Pack the grid once: r, g, b and the luma deviation per cell.
  final grid = Float32List(gw * gh * 4);
  for (var i = 0; i < gw * gh; i++) {
    final wgt = weights[i];
    if (total == 0 || wgt <= 1e-6) {
      // 周囲が全くない（写真全体を隠す）ときだけ無彩色で埋める。
      grid[i * 4] = grid[i * 4 + 1] = grid[i * 4 + 2] = 128;
      grid[i * 4 + 3] = 0;
      continue;
    }
    final r = sums[i * 3] / wgt,
        g = sums[i * 3 + 1] / wgt,
        b = sums[i * 3 + 2] / wgt;
    final luma = .299 * r + .587 * g + .114 * b;
    final variance = squares[i] / wgt - luma * luma;
    grid[i * 4] = r;
    grid[i * 4 + 1] = g;
    grid[i * 4 + 2] = b;
    grid[i * 4 + 3] = variance > 0
        ? math.min(10.0, math.sqrt(variance) * .6)
        : 0;
  }

  // 縁: 内側は 1、外側は距離に応じて 0 へ。内側の内容が残る方向にはぼかさない。
  final alpha = Float32List(bw * bh);
  for (var i = 0; i < alpha.length; i++) {
    alpha[i] = inside[i].toDouble();
  }
  _boxBlur32(alpha, bw, bh, feather.round());
  final seed =
      s.left * 73856093 ^ s.top * 19349663 ^ s.right * 83492791 ^ s.bottom;
  final sample = Float32List(4);
  for (var y = 0; y < bh; y++) {
    final fy = (bandTop + y - top + .5) * scale - .5;
    for (var x = 0; x < bw; x++) {
      final i = y * bw + x;
      final a = inside[i] != 0 ? 1.0 : (alpha[i] * 2).clamp(0.0, 1.0);
      if (a <= 0) continue;
      _sampleGrid(
        grid,
        gw,
        gh,
        (bandLeft + x - left + .5) * scale - .5,
        fy,
        sample,
      );
      final noise = sample[3] == 0
          ? 0.0
          : _noise(bandLeft + x, bandTop + y, seed) * sample[3];
      final int p = ((bandTop + y) * width + bandLeft + x) * channels;
      px[p] = _mix(px[p], sample[0] + noise, a);
      px[p + 1] = _mix(px[p + 1], sample[1] + noise, a);
      px[p + 2] = _mix(px[p + 2], sample[2] + noise, a);
    }
  }
}

/// Bilinear sample of the packed grid into [out] (r, g, b, noise amplitude).
void _sampleGrid(
  Float32List grid,
  int gw,
  int gh,
  double fx,
  double fy,
  Float32List out,
) {
  final x0 = fx.floor().clamp(0, gw - 1);
  final y0 = fy.floor().clamp(0, gh - 1);
  final x1 = math.min(gw - 1, x0 + 1);
  final y1 = math.min(gh - 1, y0 + 1);
  final tx = (fx - x0).clamp(0.0, 1.0);
  final ty = (fy - y0).clamp(0.0, 1.0);
  final a = (y0 * gw + x0) * 4, b = (y0 * gw + x1) * 4;
  final c = (y1 * gw + x0) * 4, d = (y1 * gw + x1) * 4;
  for (var k = 0; k < 4; k++) {
    out[k] =
        (grid[a + k] * (1 - tx) + grid[b + k] * tx) * (1 - ty) +
        (grid[c + k] * (1 - tx) + grid[d + k] * tx) * ty;
  }
}

int _mix(int original, double fill, double a) =>
    (original * (1 - a) + fill.clamp(0, 255) * a).round().clamp(0, 255);

/// [-1, 1] の三角分布に近い決定的な雑音。座標と形で決まり、再実行で変わらない。
double _noise(int x, int y, int seed) {
  var h = (x * 374761393 + y * 668265263 + seed * 2246822519) & 0x7fffffff;
  h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff;
  final a = (h & 0xffff) / 65535;
  final b = ((h >> 15) & 0xffff) / 65535;
  return a + b - 1;
}

/// 分離可能な移動平均。端は範囲内の画素だけで平均する。
void _boxBlur(Float64List data, int w, int h, int stride, int radius) {
  final line = Float64List(math.max(w, h));
  for (var c = 0; c < stride; c++) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        line[x] = data[(y * w + x) * stride + c];
      }
      _blurLine(line, w, radius, (x, v) => data[(y * w + x) * stride + c] = v);
    }
    for (var x = 0; x < w; x++) {
      for (var y = 0; y < h; y++) {
        line[y] = data[(y * w + x) * stride + c];
      }
      _blurLine(line, h, radius, (y, v) => data[(y * w + x) * stride + c] = v);
    }
  }
}

void _boxBlur32(Float32List data, int w, int h, int radius) {
  final line = Float64List(math.max(w, h));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      line[x] = data[y * w + x];
    }
    _blurLine(line, w, radius, (x, v) => data[y * w + x] = v);
  }
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      line[y] = data[y * w + x];
    }
    _blurLine(line, h, radius, (y, v) => data[y * w + x] = v);
  }
}

void _blurLine(
  Float64List line,
  int n,
  int radius,
  void Function(int, double) write,
) {
  if (radius <= 0 || n == 1) {
    for (var i = 0; i < n; i++) {
      write(i, line[i]);
    }
    return;
  }
  var sum = 0.0;
  var count = 0;
  final hi = math.min(n - 1, radius);
  for (var i = 0; i <= hi; i++) {
    sum += line[i];
    count++;
  }
  for (var i = 0; i < n; i++) {
    write(i, sum / count);
    final add = i + radius + 1;
    final drop = i - radius;
    if (add < n) {
      sum += line[add];
      count++;
    }
    if (drop >= 0) {
      sum -= line[drop];
      count--;
    }
  }
}

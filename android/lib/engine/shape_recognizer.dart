import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/point.dart';

/// 手绘图形类型。
///
/// curve = 未识别出规整图形（保留原始手绘笔迹）。
enum ShapeKind { line, rect, ellipse, triangle, arrow, curve }

/// 一次识别的结果。
///
/// [points] 是**规整化后的几何控制点**（不再是原始采样点）：
///  - line / arrow : 2 点，arrow 的 [1] 为箭头尖端
///  - rect         : 2 点（轴对齐对角）或 4 点（旋转矩形四角，顺时针）
///  - ellipse      : 2 点（包围盒对角）
///  - triangle     : 3 点（三个顶点）
///  - curve        : 原始手绘点
class RecognizedShape {
  final ShapeKind kind;
  final List<Point> points;
  final double score; // 0..1 置信度

  const RecognizedShape(this.kind, this.points, this.score);

  bool get isGeometry => kind != ShapeKind.curve;
}

/// 手绘图形识别 + 形状美化引擎。
///
/// 对标 GoodNotes / PSPDFKit 的 ShapeRecognition：
///  - 随手画一笔 → 识别成 直线 / 矩形 / 椭圆(正圆) / 三角形 / 箭头
///  - 识别结果经 shapeBeautifier 规整：水平垂直吸附、45° 斜线、正方形、
///    正圆、等边与等腰直角三角、箭头头部朝向
///  - 判定全部基于几何特征（闭合度 / 直线度 / 圆度 / 矩形度 /
///    凸包内最大面积三角形 / 曲率角点 / 端点回勾），无外部依赖，可离线运行。
///
/// 复杂度：重采样到 48 点后，凸包 O(n log n)、最大面积三角形 O(h³)、
/// 最小外接矩形旋转卡壳 O(h·n)，单笔在毫秒级完成。
class ShapeRecognizer {
  ShapeRecognizer._();

  // —— 判定阈值（[tolerance] 会整体缩放，对应 shapeSelectionTolerance）——
  //
  // 阈值都用实测合成笔画标定过（见仓库根目录 _shape_test.py，24 例 × 3 档 tolerance
  // 全部通过）。各形状的典型特征值：
  //   圆/椭圆 : 圆度 0.87~0.98，矩形度 ≈0.79，三角度 ≈0.43，绕行 ≈1.00
  //   矩形    : 圆度 ≈0.79，  矩形度 0.98，   三角度 ≈0.49，绕行 ≈1.01
  //   三角形  : 圆度 0.58~0.64，矩形度 ≈0.54，三角度 0.92， 绕行 ≈0.98
  //   涂鸦    : 圆度 0.81，   矩形度 0.76，   三角度 0.57，绕行 2.22 ← 靠绕行排除
  //   箭头    : 直线度 0.62 + 端点回勾（波浪线直线度 0.70 但无回勾，靠回勾区分）
  static const double _closedRatio = 0.28; // 弦长/路径长 < 此值 ⇒ 闭合
  static const double _straightMin = 0.84; // 直线度 > 此值 ⇒ 直线
  static const double _arrowStraightMin = 0.55; // 箭头所需的最低主干直线度
  static const double _detourMax = 1.45; // 绕行系数(路径长/凸包周长) > 此值 ⇒ 涂鸦
  static const double _triRatioMin = 0.86; // 最大三角形/凸包面积 ⇒ 三角
  static const double _triRatioFloor = 0.70; // 宽松档的下限
  static const double _rectRatioMin = 0.95; // 凸包/最小外接矩形面积 ⇒ 矩形
  static const double _rectRatioFloor = 0.86; // 必须高于圆的 π/4≈0.785
  static const double _circularMin = 0.78; // 圆度 ⇒ 椭圆
  static const double _circularFloor = 0.72; // 宽松档的下限
  static const double _arrowTurnDeg = 100.0; // 端点回勾夹角 ⇒ 箭头

  // —— 美化吸附容差 ——
  static const double _snapLineDeg = 8.0; // 直线吸附到 0/45/90 的容差
  static const double _snapAxisDeg = 10.0; // 矩形/椭圆吸附到水平的容差
  static const double _squareRatio = 1.16; // 宽高比在此范围内 ⇒ 正方形/正圆
  static const double _equiDeg = 14.0; // 三角内角接近 60° 的容差 ⇒ 等边
  static const double _rightDeg = 12.0; // 三角内角接近 90°/45° 的容差 ⇒ 等腰直角

  /// 主入口：识别 + 美化。返回 curve 表示未识别（应保留手绘原样）。
  ///
  /// [tolerance] 0..1，越大越宽松（更容易识别成规整图形，也更容易误判）。
  /// [snap] 是否做吸附美化（false = 只识别不规整，保留识别出的原始顶点）。
  static RecognizedShape beautify(
    List<Point> raw, {
    double tolerance = 0.5,
    bool snap = true,
  }) {
    final r = recognize(raw, tolerance: tolerance);
    if (!r.isGeometry) return r;
    if (!snap) return r;
    return _beautify(raw, r.kind, tolerance);
  }

  /// 只做识别，不做吸附美化。
  static RecognizedShape recognize(
    List<Point> raw, {
    double tolerance = 0.5,
  }) {
    if (raw.length < 4) return RecognizedShape(ShapeKind.curve, raw, 0);

    final pts = _resample(raw, 48);
    if (pts.length < 4) return RecognizedShape(ShapeKind.curve, raw, 0);

    final len = _pathLen(pts);
    final bb = _bbox(pts);
    final diag = math.sqrt(bb.width * bb.width + bb.height * bb.height);
    // 太小的一笔（像点了一下）不做识别
    if (len <= 0 || diag < 24) {
      return RecognizedShape(ShapeKind.curve, raw, 0);
    }

    final chord = (pts.last - pts.first).distance;
    final straightness = chord / len;
    final tol = tolerance.clamp(0.0, 1.0);
    // tolerance 越大 ⇒ 闭合/直线的判定越宽松
    final closedThr = _closedRatio * (1 + tol * 0.5);
    final straightThr = _straightMin * (1 - tol * 0.14);
    final closed = chord < closedThr * len;

    if (!closed) {
      // ——开放笔画：箭头 / 直线 / 曲线——
      //
      // 箭头必须**先于**直线判定：箭头自带端点回勾，整体直线度只有 0.6 上下，
      // 若先卡直线阈值（0.84）就永远识别不到。反过来，波浪线直线度也有 0.70，
      // 靠「端点回勾」与其区分。
      if (straightness > _arrowStraightMin) {
        final head = _detectArrowHead(pts, tol);
        if (head != 0) {
          final tip = head == 2 ? pts.first : pts.last; // 箭头尖端
          final tail = head == 2 ? pts.last : pts.first; // 尾端
          return RecognizedShape(
            ShapeKind.arrow,
            [Point(tail.dx, tail.dy), Point(tip.dx, tip.dy)],
            straightness,
          );
        }
      }
      if (straightness > straightThr) {
        return RecognizedShape(
          ShapeKind.line,
          [Point(pts.first.dx, pts.first.dy), Point(pts.last.dx, pts.last.dy)],
          straightness,
        );
      }
      return RecognizedShape(ShapeKind.curve, raw, 0);
    }

    // ——闭合笔画：三角 / 矩形 / 椭圆——
    final hull = _convexHull(pts);
    if (hull.length < 3) return RecognizedShape(ShapeKind.curve, raw, 0);

    final hullPerim = _polyPerim(hull);
    if (hullPerim <= 0) return RecognizedShape(ShapeKind.curve, raw, 0);

    // 绕行系数：路径长 / 凸包周长。空心轮廓 ≈1.0；涂鸦、来回涂抹会在轮廓内部
    // 反复穿越，实测 >2——这是把涂鸦挡在门外的唯一可靠判据（圆度无法区分：
    // 随机游走的凸包同样很「圆」，圆度可达 0.81）。
    final detour = len / hullPerim;
    if (detour > _detourMax) return RecognizedShape(ShapeKind.curve, raw, 0);

    final hullArea = _polyArea(hull);
    final circularity = 4 * math.pi * hullArea / (hullPerim * hullPerim);
    final mr = _minAreaRect(hull);
    final rectRatio = mr.w > 0 && mr.h > 0 ? hullArea / (mr.w * mr.h) : 0.0;
    final tri = _maxAreaTriangle(hull);
    final triRatio = hullArea > 0 ? _triArea(tri[0], tri[1], tri[2]) / hullArea : 0.0;

    // tolerance 越大 ⇒ 阈值越低；但用 floor 兜住下限，避免宽松档把圆/涂鸦
    // 误判成矩形（圆的矩形度理论上限 π/4≈0.785，矩形阈值绝不能低于它）。
    final k = 1 - tol * 0.16;
    final rectThr = math.max(_rectRatioFloor, _rectRatioMin * k);
    final triThr = math.max(_triRatioFloor, _triRatioMin * k);
    final circThr = math.max(_circularFloor, _circularMin * k);

    // 判定顺序即优先级：矩形度 → 三角度 → 圆度，三者互不重叠，无需角点检测。
    if (rectRatio > rectThr) {
      return RecognizedShape(ShapeKind.rect, _rectPts(mr), rectRatio);
    }
    if (triRatio > triThr) {
      return RecognizedShape(
        ShapeKind.triangle,
        tri.map((o) => Point(o.dx, o.dy)).toList(),
        triRatio,
      );
    }
    if (circularity > circThr) {
      return RecognizedShape(ShapeKind.ellipse, _rectPts(mr), circularity);
    }
    // 兜底档（略放宽，覆盖画得比较潦草但仍明显是某个形状的笔画）
    if (rectRatio > 0.84) {
      return RecognizedShape(ShapeKind.rect, _rectPts(mr), rectRatio);
    }
    if (triRatio > 0.66) {
      return RecognizedShape(
        ShapeKind.triangle,
        tri.map((o) => Point(o.dx, o.dy)).toList(),
        triRatio,
      );
    }
    if (circularity > 0.66) {
      return RecognizedShape(ShapeKind.ellipse, _rectPts(mr), circularity);
    }
    return RecognizedShape(ShapeKind.curve, raw, 0);
  }

  // ============ 美化（shapeBeautifier）============

  static RecognizedShape _beautify(
      List<Point> raw, ShapeKind kind, double tolerance) {
    final pts = _resample(raw, 48);
    switch (kind) {
      case ShapeKind.line:
        return _beautifyLine(pts);
      case ShapeKind.arrow:
        return _beautifyArrow(pts, tolerance);
      case ShapeKind.rect:
        return _beautifyRect(pts);
      case ShapeKind.ellipse:
        return _beautifyEllipse(pts);
      case ShapeKind.triangle:
        return _beautifyTriangle(pts);
      case ShapeKind.curve:
        return RecognizedShape(kind, raw, 0);
    }
  }

  static RecognizedShape _beautifyLine(List<Offset> pts) {
    var a = pts.first;
    var b = pts.last;
    var ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
    // 直线无方向：规范化到 [-90°, 90°)
    while (ang >= math.pi / 2) ang -= math.pi;
    while (ang < -math.pi / 2) ang += math.pi;
    final s = _snapAngle(ang, math.pi / 4, _snapLineDeg * math.pi / 180);
    if (s != ang) {
      final L = (b - a).distance;
      b = Offset(a.dx + math.cos(s) * L, a.dy + math.sin(s) * L);
    }
    return RecognizedShape(
        ShapeKind.line, [Point(a.dx, a.dy), Point(b.dx, b.dy)], 1);
  }

  static RecognizedShape _beautifyArrow(List<Offset> pts, double tolerance) {
    final head = _detectArrowHead(pts, tolerance);
    if (head == 0) return _beautifyLine(pts);
    final tip = head == 2 ? pts.first : pts.last;
    final tail = head == 2 ? pts.last : pts.first;
    // 主干方向取中段（避开两端回勾干扰）
    final n = pts.length;
    final m0 = pts[(n * 0.40).round()];
    final m1 = pts[(n * 0.60).round()];
    var ang = math.atan2(m1.dy - m0.dy, m1.dx - m0.dx);
    while (ang >= math.pi / 2) ang -= math.pi;
    while (ang < -math.pi / 2) ang += math.pi;
    final s = _snapAngle(ang, math.pi / 4, _snapLineDeg * math.pi / 180);
    final dirX = math.cos(s);
    final dirY = math.sin(s);
    // 尖端在中段方向的哪一侧 → 尾端沿反方向外推
    final sign = ((tip.dx - m0.dx) * dirX + (tip.dy - m0.dy) * dirY) >= 0
        ? 1.0
        : -1.0;
    // 长度取首尾在主轴上的投影，避免规整后长度跳变
    final proj = ((tail.dx - tip.dx) * dirX + (tail.dy - tip.dy) * dirY).abs();
    final t = Offset(tip.dx - sign * dirX * proj, tip.dy - sign * dirY * proj);
    return RecognizedShape(
        ShapeKind.arrow, [Point(t.dx, t.dy), Point(tip.dx, tip.dy)], 1);
  }

  static RecognizedShape _beautifyRect(List<Offset> pts) {
    final hull = _convexHull(pts);
    if (hull.length < 3) return RecognizedShape(ShapeKind.curve, _toPts(pts), 0);
    final mr = _minAreaRect(hull);
    final ang = _norm90(mr.angle);
    final tol = _snapAxisDeg * math.pi / 180;

    // 角度吸附：接近水平/垂直 ⇒ 直接用轴对齐包围盒（笔记场景绝大多数如此）
    final bb = _bbox(pts);
    final axisAligned = ang.abs() < tol || (ang.abs() - math.pi / 2).abs() < tol;
    final center = axisAligned ? bb.center : mr.center;
    var w = axisAligned ? bb.width : mr.w;
    var h = axisAligned ? bb.height : mr.h;
    // 正方形吸附
    final ratio = w / h;
    if (ratio > 1 / _squareRatio && ratio < _squareRatio) {
      final s = (w + h) / 2;
      w = s;
      h = s;
    }
    if (axisAligned) {
      return RecognizedShape(
        ShapeKind.rect,
        [
          Point(center.dx - w / 2, center.dy - h / 2),
          Point(center.dx + w / 2, center.dy + h / 2),
        ],
        1,
      );
    }
    // 明显倾斜的矩形：输出 4 个角点，保留原旋转角
    final c = math.cos(ang);
    final s = math.sin(ang);
    final hw = w / 2;
    final hh = h / 2;
    final out = <Point>[];
    for (final e in [
      (-hw, -hh),
      (hw, -hh),
      (hw, hh),
      (-hw, hh),
    ]) {
      out.add(Point(
        center.dx + e.$1 * c - e.$2 * s,
        center.dy + e.$1 * s + e.$2 * c,
      ));
    }
    return RecognizedShape(ShapeKind.rect, out, 1);
  }

  static RecognizedShape _beautifyEllipse(List<Offset> pts) {
    final hull = _convexHull(pts);
    if (hull.length < 3) return RecognizedShape(ShapeKind.curve, _toPts(pts), 0);
    // 旋转椭圆统一退化为轴对齐椭圆：Flutter 的 addOval 只吃 Rect，
    // 不带旋转参数（真要斜椭圆得走 canvas 变换，笔记场景收益很小）。
    final r = _bbox(pts);
    var w = r.width;
    var h = r.height;
    final ratio = w / h;
    if (ratio > 1 / _squareRatio && ratio < _squareRatio) {
      final s = (w + h) / 2;
      w = s;
      h = s;
    }
    final c = r.center;
    return RecognizedShape(
      ShapeKind.ellipse,
      [
        Point(c.dx - w / 2, c.dy - h / 2),
        Point(c.dx + w / 2, c.dy + h / 2),
      ],
      1,
    );
  }

  static RecognizedShape _beautifyTriangle(List<Offset> pts) {
    final hull = _convexHull(pts);
    if (hull.length < 3) return RecognizedShape(ShapeKind.curve, _toPts(pts), 0);
    final t = _maxAreaTriangle(hull);
    final a = t[0], b = t[1], c = t[2];
    final ab = (b - a).distance;
    final bc = (c - b).distance;
    final ca = (a - c).distance;

    // 1) 等边：三边长度接近
    final mx = math.max(ab, math.max(bc, ca));
    final mn = math.min(ab, math.min(bc, ca));
    if (mn > 0 && mx / mn < 1.28 && _allAnglesNear(t, math.pi / 3, _equiDeg)) {
      return _equilateral(a, b, c);
    }

    // 2) 等腰直角：找最接近 90° 的角
    final tri = [a, b, c];
    var bestI = -1;
    var bestErr = double.infinity;
    for (var i = 0; i < 3; i++) {
      final v = tri[i];
      final p1 = tri[(i + 1) % 3];
      final p2 = tri[(i + 2) % 3];
      final ang = _angleAt(v, p1, p2);
      final err = (ang - math.pi / 2).abs();
      if (err < bestErr) {
        bestErr = err;
        bestI = i;
      }
    }
    if (bestErr < _rightDeg * math.pi / 180) {
      final v = tri[bestI];
      final p1 = tri[(bestI + 1) % 3];
      final p2 = tri[(bestI + 2) % 3];
      final l1 = (p1 - v).distance;
      final l2 = (p2 - v).distance;
      if (math.max(l1, l2) / math.max(1e-6, math.min(l1, l2)) < 1.45) {
        return _rightIsosceles(v, p1, p2, (l1 + l2) / 2);
      }
    }

    // 3) 底边水平吸附：把最接近水平的边摆正
    final edges = [
      (a, b, c),
      (b, c, a),
      (c, a, b),
    ];
    var bi = 0;
    var bErr = double.infinity;
    for (var i = 0; i < 3; i++) {
      final e = edges[i];
      var ang = math.atan2(e.$2.dy - e.$1.dy, e.$2.dx - e.$1.dx);
      while (ang >= math.pi / 2) ang -= math.pi;
      while (ang < -math.pi / 2) ang += math.pi;
      final err = ang.abs();
      if (err < bErr) {
        bErr = err;
        bi = i;
      }
    }
    final e = edges[bi];
    if (bErr < _snapAxisDeg * math.pi / 180) {
      // 底边拉平，第三个点保持水平位置与到直线的高度
      final p0 = e.$1;
      final p1 = e.$2;
      final apex = e.$3;
      final y = (p0.dy + p1.dy) / 2;
      final left = math.min(p0.dx, p1.dx);
      final right = math.max(p0.dx, p1.dx);
      final side = apex.dy < y ? -1.0 : 1.0;
      final height = (apex.dy - y).abs();
      final cx = apex.dx.clamp(left, right);
      return RecognizedShape(
        ShapeKind.triangle,
        [
          Point(left, y),
          Point(right, y),
          Point(cx, y + side * height),
        ],
        1,
      );
    }
    return RecognizedShape(
        ShapeKind.triangle, t.map((o) => Point(o.dx, o.dy)).toList(), 1);
  }

  /// 以最长边为底构造正三角形（顶点取原顶点所在侧）。
  static RecognizedShape _equilateral(Offset a, Offset b, Offset c) {
    final tri = [a, b, c];
    var li = 0;
    var ll = -1.0;
    for (var i = 0; i < 3; i++) {
      final d = (tri[i] - tri[(i + 1) % 3]).distance;
      if (d > ll) {
        ll = d;
        li = i;
      }
    }
    final p0 = tri[li];
    final p1 = tri[(li + 1) % 3];
    final apex = tri[(li + 2) % 3];
    final mx = (p0.dx + p1.dx) / 2;
    final my = (p0.dy + p1.dy) / 2;
    var dx = p1.dx - p0.dx;
    var dy = p1.dy - p0.dy;
    final L = math.sqrt(dx * dx + dy * dy);
    if (L <= 0) {
      return RecognizedShape(
          ShapeKind.triangle, tri.map((o) => Point(o.dx, o.dy)).toList(), 1);
    }
    dx /= L;
    dy /= L;
    // 法线（两个方向），取靠原顶点的一侧
    var nx = -dy;
    var ny = dx;
    if ((apex.dx - mx) * nx + (apex.dy - my) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    final h = L * math.sqrt(3) / 2;
    return RecognizedShape(
      ShapeKind.triangle,
      [
        Point(p0.dx, p0.dy),
        Point(p1.dx, p1.dy),
        Point(mx + nx * h, my + ny * h),
      ],
      1,
    );
  }

  /// 以 [v] 为直角顶点构造等腰直角三角形（两腰沿角平分线 ±45°）。
  static RecognizedShape _rightIsosceles(
      Offset v, Offset p1, Offset p2, double len) {
    var a1 = math.atan2(p1.dy - v.dy, p1.dx - v.dx);
    var a2 = math.atan2(p2.dy - v.dy, p2.dx - v.dx);
    // 取夹角较小的那一侧的中分方向
    var d = a2 - a1;
    while (d > math.pi) d -= 2 * math.pi;
    while (d < -math.pi) d += 2 * math.pi;
    final bis = a1 + d / 2;
    final half = math.pi / 4;
    final q1 = Offset(v.dx + math.cos(bis - half) * len,
        v.dy + math.sin(bis - half) * len);
    final q2 = Offset(v.dx + math.cos(bis + half) * len,
        v.dy + math.sin(bis + half) * len);
    return RecognizedShape(
      ShapeKind.triangle,
      [Point(q1.dx, q1.dy), Point(v.dx, v.dy), Point(q2.dx, q2.dy)],
      1,
    );
  }

  // ============ 判别辅助 ============

  /// 端点回勾检测：0=无箭头，1=终点箭头（绝大多数），2=起点箭头。
  ///
  /// 两个互补判据（任一命中即算回勾）：
  ///  1) 绕行率：端点段的「路径长度 / 净位移」远大于 1 ⇒ 端点处有折返。
  ///     直线的比值 ≈ 1；箭头回勾通常 > 3，非常稳健。
  ///  2) 方向反转：端点段净位移与主干方向夹角超过阈值。
  static int _detectArrowHead(List<Offset> pts, double tolerance) {
    final n = pts.length;
    if (n < 12) return 0;
    final i1 = (n * 0.30).round();
    final i2 = (n * 0.70).round();
    final mid = pts[i2] - pts[i1];
    if (mid.distance < 1e-6) return 0;

    final turnThr = (_arrowTurnDeg - tolerance * 20) * math.pi / 180;
    const detourThr = 1.5;

    // 尾段（后 30%）
    var tailPath = 0.0;
    for (var i = i2 + 1; i < n; i++) {
      tailPath += (pts[i] - pts[i - 1]).distance;
    }
    final tailVec = pts.last - pts[i2];
    final tailChord = tailVec.distance;
    final tailArrow = tailChord > 0 && tailPath > tailChord * detourThr ||
        (tailChord > 1e-6 && _angBetween(mid, tailVec) > turnThr);

    // 首段（前 30%）
    var headPath = 0.0;
    for (var i = 1; i <= i1; i++) {
      headPath += (pts[i] - pts[i - 1]).distance;
    }
    final headVec = pts.first - pts[i1];
    final headChord = headVec.distance;
    final headArrow = headChord > 0 && headPath > headChord * detourThr ||
        (headChord > 1e-6 && _angBetween(-mid, headVec) > turnThr);

    if (tailArrow && !headArrow) return 1;
    if (headArrow && !tailArrow) return 2;
    if (tailArrow && headArrow) return 1; // 两端都回勾：按终点箭头处理
    return 0;
  }

  static double _angBetween(Offset u, Offset v) {
    final d = u.dx * v.dx + u.dy * v.dy;
    final nu = u.distance;
    final nv = v.distance;
    if (nu <= 0 || nv <= 0) return 0;
    return math.acos((d / (nu * nv)).clamp(-1.0, 1.0));
  }

  static double _angleAt(Offset v, Offset p1, Offset p2) =>
      _angBetween(p1 - v, p2 - v);

  static bool _allAnglesNear(List<Offset> t, double target, double degTol) {
    for (var i = 0; i < 3; i++) {
      final ang = _angleAt(t[i], t[(i + 1) % 3], t[(i + 2) % 3]);
      if ((ang - target).abs() > degTol * math.pi / 180) return false;
    }
    return true;
  }

  static double _snapAngle(double a, double step, double tol) {
    final k = (a / step).round();
    final s = k * step;
    return (a - s).abs() <= tol ? s : a;
  }

  /// 规范化到 (-90°, 90°]（矩形/椭圆的对称轴周期）。
  static double _norm90(double a) {
    var x = a % math.pi;
    if (x > math.pi / 2) x -= math.pi;
    if (x <= -math.pi / 2) x += math.pi;
    return x;
  }

  // ============ 几何基元 ============

  static List<Point> _toPts(List<Offset> o) =>
      o.map((e) => Point(e.dx, e.dy)).toList();

  static Rect _bbox(List<Offset> p) {
    var minX = p.first.dx, maxX = p.first.dx;
    var minY = p.first.dy, maxY = p.first.dy;
    for (final q in p) {
      if (q.dx < minX) minX = q.dx;
      if (q.dx > maxX) maxX = q.dx;
      if (q.dy < minY) minY = q.dy;
      if (q.dy > maxY) maxY = q.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static double _pathLen(List<Offset> p) {
    var s = 0.0;
    for (var i = 1; i < p.length; i++) s += (p[i] - p[i - 1]).distance;
    return s;
  }

  /// 等距重采样到 [n] 个点。
  static List<Offset> _resample(List<Point> src, int n) {
    final raw = <Offset>[];
    for (final q in src) {
      final o = Offset(q.x, q.y);
      if (raw.isEmpty || (o - raw.last).distance > 0.01) raw.add(o);
    }
    if (raw.length < 2) return raw;
    final cum = <double>[0.0];
    for (var i = 1; i < raw.length; i++) {
      cum.add(cum[i - 1] + (raw[i] - raw[i - 1]).distance);
    }
    final total = cum.last;
    if (total <= 0) return raw;
    final step = total / (n - 1);
    final out = <Offset>[raw.first];
    var idx = 1;
    var d = step;
    while (out.length < n - 1 && idx < raw.length) {
      while (idx < raw.length && cum[idx] < d) {
        idx++;
      }
      if (idx >= raw.length) break;
      final segLen = cum[idx] - cum[idx - 1];
      final t = segLen > 0 ? ((d - cum[idx - 1]) / segLen).clamp(0.0, 1.0) : 0.0;
      out.add(Offset(
        raw[idx - 1].dx + (raw[idx].dx - raw[idx - 1].dx) * t,
        raw[idx - 1].dy + (raw[idx].dy - raw[idx - 1].dy) * t,
      ));
      d += step;
    }
    out.add(raw.last);
    return out;
  }

  /// Andrew monotone chain 凸包。
  static List<Offset> _convexHull(List<Offset> pts) {
    if (pts.length < 3) return List<Offset>.from(pts);
    final p = List<Offset>.from(pts)
      ..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    double cross(Offset o, Offset a, Offset b) =>
        (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final lower = <Offset>[];
    for (final q in p) {
      while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, q) <= 0) {
        lower.removeLast();
      }
      lower.add(q);
    }
    final upper = <Offset>[];
    for (final q in p.reversed) {
      while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, q) <= 0) {
        upper.removeLast();
      }
      upper.add(q);
    }
    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  static double _polyArea(List<Offset> p) {
    var a = 0.0;
    for (var i = 0; i < p.length; i++) {
      final j = (i + 1) % p.length;
      a += p[i].dx * p[j].dy - p[j].dx * p[i].dy;
    }
    return (a / 2).abs();
  }

  static double _polyPerim(List<Offset> p) {
    var s = 0.0;
    for (var i = 0; i < p.length; i++) {
      s += (p[(i + 1) % p.length] - p[i]).distance;
    }
    return s;
  }

  static double _triArea(Offset a, Offset b, Offset c) =>
      ((b.dx - a.dx) * (c.dy - a.dy) - (c.dx - a.dx) * (b.dy - a.dy)).abs() / 2;

  /// 凸包内最大面积三角形（对应 GoodNotes `maximumAreaTriangleInConvexHull:`）。
  /// 凸包点数通常 < 25，O(h³) 足够快。
  static List<Offset> _maxAreaTriangle(List<Offset> hull) {
    final n = hull.length;
    if (n < 3) return List<Offset>.from(hull);
    if (n == 3) return List<Offset>.from(hull);
    var best = -1.0;
    var bi = 0, bj = 1, bk = 2;
    for (var i = 0; i < n - 2; i++) {
      for (var j = i + 1; j < n - 1; j++) {
        for (var k = j + 1; k < n; k++) {
          final a = _triArea(hull[i], hull[j], hull[k]);
          if (a > best) {
            best = a;
            bi = i;
            bj = j;
            bk = k;
          }
        }
      }
    }
    return [hull[bi], hull[bj], hull[bk]];
  }

  /// 最小面积外接矩形（旋转卡壳：枚举凸包每条边作为底边）。
  static _RotRect _minAreaRect(List<Offset> hull) {
    final n = hull.length;
    if (n < 3) {
      final bb = _bbox(hull);
      return _RotRect(bb.center, bb.width, bb.height, 0);
    }
    var bestArea = double.infinity;
    var best = _RotRect(hull.first, 0, 0, 0);
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final dx = hull[j].dx - hull[i].dx;
      final dy = hull[j].dy - hull[i].dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len <= 0) continue;
      final ang = math.atan2(dy, dx);
      final ca = math.cos(-ang);
      final sa = math.sin(-ang);
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final q in hull) {
        final x = q.dx * ca - q.dy * sa;
        final y = q.dx * sa + q.dy * ca;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      final w = maxX - minX;
      final h = maxY - minY;
      final area = w * h;
      if (area < bestArea) {
        bestArea = area;
        final cx = (minX + maxX) / 2;
        final cy = (minY + maxY) / 2;
        final cb = math.cos(ang);
        final sb = math.sin(ang);
        best = _RotRect(Offset(cx * cb - cy * sb, cx * sb + cy * cb), w, h, ang);
      }
    }
    return best;
  }

  static List<Point> _rectPts(_RotRect r) {
    final c = math.cos(r.angle);
    final s = math.sin(r.angle);
    final hw = r.w / 2;
    final hh = r.h / 2;
    final out = <Point>[];
    for (final e in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]) {
      out.add(Point(
        r.center.dx + e.$1 * c - e.$2 * s,
        r.center.dy + e.$1 * s + e.$2 * c,
      ));
    }
    return out;
  }

}

class _RotRect {
  final Offset center;
  final double w;
  final double h;
  final double angle;
  const _RotRect(this.center, this.w, this.h, this.angle);
}

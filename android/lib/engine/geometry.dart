import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/point.dart';
import '../models/stroke.dart';
import '../models/tool.dart';

/// 统一几何运算 —— 笔迹命中测试 / 套索 / 擦除 的公共地基。
///
/// 参考 Notein penkit 的设计要点：
/// - **缓存 bounds**（对应其 `DrawRecord.bounds` / `TypedRect.center`）：
///   每条笔画的 AABB 只算一次，命中测试、套索粗筛、选中框都复用。
///   用 [Expando] 而非静态 Map —— 笔画对象被回收时缓存自动释放，不会内存泄漏。
/// - **命中判定走几何运算，而非比采样点**（对应其「橡皮擦/套索走几何运算」）：
///   快速书写时采样点很稀疏，若只比较「圆心到采样点」的距离，
///   相邻两个采样点可能在圆外、但两点之间的线段却穿过圆 → 漏判。
///   因此统一用「点到**线段**」的最短距离。
/// - **两级判定**：AABB 粗筛（O(1) 排除绝大多数）+ 精确几何判定。
class Geometry {
  Geometry._();

  /// 笔画 AABB 缓存（键为 Stroke 对象，随对象回收）。
  static final Expando<Rect> _boundsCache = Expando<Rect>('strokeBounds');

  /// 笔画的轴对齐包围盒（带缓存）。
  static Rect boundsOf(Stroke s) {
    final hit = _boundsCache[s];
    if (hit != null) return hit;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in s.points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    if (minX == double.infinity) {
      return Rect.zero; // 空笔画
    }
    final r = Rect.fromLTRB(minX, minY, maxX, maxY);
    _boundsCache[s] = r;
    return r;
  }

  /// 一组点的 AABB。
  static Rect aabbOfOffsets(List<Offset> pts) {
    if (pts.isEmpty) return Rect.zero;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 多条笔画合并后的 AABB（选中框用，复用单笔画缓存）。
  static Rect aabbOfStrokes(List<Stroke> ss) {
    if (ss.isEmpty) return Rect.zero;
    Rect? out;
    for (final s in ss) {
      final b = boundsOf(s);
      out = out == null ? b : out.expandToInclude(b);
    }
    return out ?? Rect.zero;
  }

  /// 点 [p] 到线段 [a]-[b] 的最短距离。
  static double distPointSegment(Offset p, Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / len2;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }
    final px = a.dx + t * dx;
    final py = a.dy + t * dy;
    final ex = p.dx - px;
    final ey = p.dy - py;
    return math.sqrt(ex * ex + ey * ey);
  }

  /// 笔画是否与圆 (c, r) 相交 —— 擦除/命中测试用。
  ///
  /// 粗筛：圆心必须落在「笔画 AABB 向外扩 r」的矩形内。这是保守上界：
  /// 笔画上任意点 q 满足 q ∈ AABB，若 |c-q| ≤ r 则 c ∈ AABB.inflate(r)。
  /// 精判：圆心到任意采样线段的距离 ≤ r。
  static bool strokeHitsCircle(Stroke s, Offset c, double r) {
    if (s.points.isEmpty) return false;
    if (!boundsOf(s).inflate(r).contains(c)) return false;
    // 形状用真实轮廓判定，否则 2 点矩形只剩一条对角线可判，擦边擦不掉
    final poly = hitPoints(s);
    if (poly.length == 1) return (poly[0] - c).distance <= r;

    final n = poly.length;
    // 闭合形状（矩形/椭圆/三角）要补上「末点→首点」的闭合边
    final segs = isClosedShape(s) ? n : n - 1;
    for (var i = 0; i < segs; i++) {
      if (distPointSegment(c, poly[i], poly[(i + 1) % n]) <= r) return true;
    }
    return false;
  }

  /// 形状笔画的**真实几何轮廓**（命中测试 / 套索 / 擦除 用）。
  ///
  /// 为什么需要：形状笔画的 [Stroke.points] 存的是**控制点**
  /// （rect / ellipse 只有 2 个对角点，triangle 3 个顶点），
  /// 拿控制点直接连线做判定，等于只判一条对角线 ——
  /// 于是「套索框住矩形角落」「橡皮擦矩形的边」都命中不了。
  /// 这里把控制点还原成真实轮廓后再判定。
  ///
  /// 控制点约定与 [Freehand] / ShapeRecognizer 输出一致。
  static List<Offset> shapeOutline(Stroke s) {
    final p = s.points;
    if (p.length < 2) return [for (final e in p) Offset(e.x, e.y)];
    switch (s.tool) {
      case Tool.rect:
        if (p.length >= 4) {
          // 旋转矩形：控制点即四角，闭合后再判定
          return [for (var i = 0; i < 4; i++) Offset(p[i].x, p[i].y)];
        }
        final a = p.first, b = p.last;
        return [
          Offset(a.x, a.y),
          Offset(b.x, a.y),
          Offset(b.x, b.y),
          Offset(a.x, b.y),
        ];
      case Tool.ellipse:
        // 旋转过的椭圆：控制点已是轮廓采样点，直接拿来判定（比再次近似更准）
        if (p.length > 2) {
          return [for (final e in p) Offset(e.x, e.y)];
        }
        // 内接正 16 边形近似（命中测试足够，且比真实椭圆判定便宜）
        final a = p.first, b = p.last;
        final cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
        final rx = (b.x - a.x).abs() / 2, ry = (b.y - a.y).abs() / 2;
        const n = 16;
        return [
          for (var i = 0; i < n; i++)
            Offset(cx + rx * math.cos(2 * math.pi * i / n),
                cy + ry * math.sin(2 * math.pi * i / n)),
        ];
      case Tool.triangle:
        if (p.length >= 3) {
          return [
            Offset(p[0].x, p[0].y),
            Offset(p[1].x, p[1].y),
            Offset(p[2].x, p[2].y),
          ];
        }
        final a = p.first, b = p.last;
        return [
          Offset((a.x + b.x) / 2, a.y),
          Offset(b.x, b.y),
          Offset(a.x, b.y),
        ];
      default:
        // line / arrow：控制点连线本身就是真实形状
        return [for (final e in p) Offset(e.x, e.y)];
    }
  }

  /// 命中测试用的点集：形状取真实轮廓，普通笔迹取采样点。
  ///
  /// 擦除 / 套索 / 方框选择 三处判定都走这里，避免各处各自拿控制点连线
  /// 判定导致形状（尤其 2 点矩形/椭圆）漏判。
  static List<Offset> hitPoints(Stroke s) =>
      s.isShape ? shapeOutline(s) : [for (final e in s.points) Offset(e.x, e.y)];

  /// 是否为闭合形状（矩形 / 椭圆 / 三角）—— 命中判定需补闭合边。
  static bool isClosedShape(Stroke s) =>
      s.isShape &&
      (s.tool == Tool.rect ||
          s.tool == Tool.ellipse ||
          s.tool == Tool.triangle);

  /// 采样点 [i] 是否被橡皮圆 (c, r) 触及 —— 区域擦除（按点剔除）用。
  ///
  /// 除「点到圆心」外，还检查与前后相邻两条线段的距离，
  /// 这样即使采样稀疏、采样点自身都在圆外，只要笔迹**穿过**了圆形区域也会被擦掉。
  static bool pointTouchedByCircle(List<Point> pts, int i, Offset c, double r) {
    final cur = Offset(pts[i].x, pts[i].y);
    if ((cur - c).distance <= r) return true;
    if (i > 0) {
      final prev = Offset(pts[i - 1].x, pts[i - 1].y);
      if (distPointSegment(c, prev, cur) <= r) return true;
    }
    if (i < pts.length - 1) {
      final next = Offset(pts[i + 1].x, pts[i + 1].y);
      if (distPointSegment(c, cur, next) <= r) return true;
    }
    return false;
  }

  /// 射线法：点是否在多边形内。
  static bool pointInPolygon(Offset p, List<Offset> poly) {
    var inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i];
      final b = poly[j];
      if (((a.dy > p.dy) != (b.dy > p.dy)) &&
          (p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx)) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// 两线段是否真相交（不含共线接触，够用且数值稳定）。
  static bool _segIntersects(Offset a, Offset b, Offset c, Offset d) {
    final o1 = _orient(a, b, c);
    final o2 = _orient(a, b, d);
    final o3 = _orient(c, d, a);
    final o4 = _orient(c, d, b);
    return ((o1 > 0) != (o2 > 0)) && ((o3 > 0) != (o4 > 0));
  }

  static double _orient(Offset p, Offset q, Offset r) =>
      (q.dx - p.dx) * (r.dy - p.dy) - (q.dy - p.dy) * (r.dx - p.dx);

  /// 笔画是否与套索多边形相交（选中判定）。
  ///
  /// 语义：**只要笔迹有一部分落在套索区域内即选中**
  /// （GoodNotes/Notein 的套索行为；旧的「只判断 AABB 中心是否在多边形内」会漏掉
  /// 长笔画被部分圈住的情况——包围盒中心在圈外但笔画实际穿过了选区）。
  ///
  /// - 粗筛：笔画 AABB 与套索 AABB 不相交直接排除。
  /// - 精判 1：任一采样点在多边形内。
  /// - 精判 2：任一笔画线段与任一多边形边相交（覆盖「笔迹横穿套索边界」的情况）。
  static bool strokeIntersectsPolygon(Stroke s, List<Offset> poly) {
    if (s.points.isEmpty || poly.length < 3) return false;
    if (!boundsOf(s).overlaps(aabbOfOffsets(poly))) return false;

    // 形状用真实轮廓：否则 2 点矩形/椭圆只有一条对角线参与判定，
    // 套索框住矩形角落（不含端点、不与对角线相交）会漏选。
    final pts = hitPoints(s);
    for (final pt in pts) {
      if (pointInPolygon(pt, poly)) return true;
    }
    if (pts.length == 1) return false;

    // 闭合形状补上「末点→首点」的闭合边
    final m = pts.length;
    final segs = isClosedShape(s) ? m : m - 1;
    final n = poly.length;
    for (var i = 0; i < segs; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % m];
      for (var j = 0; j < n; j++) {
        if (_segIntersects(a, b, poly[j], poly[(j + 1) % n])) return true;
      }
    }
    return false;
  }
}

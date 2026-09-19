import 'dart:math' as math;
import 'dart:ui' as ui;

import '../models/point.dart';
import '../models/stroke.dart';

/// 智能钢笔（z_math）—— 变宽笔迹引擎。
///
/// 移植自 z_math.js（其算法源头是 C 版 `z_math.h/.c`），与 perfect_freehand
/// 是**两条完全不同的路子**：
///  - perfect_freehand：由中心线生成**闭合轮廓多边形**再填充；
///  - z_math：沿中心线按「45% 半径」的间距**盖一串圆点**，所有圆合成一个 Path
///    一次 fill，nonzero 缠绕规则自动取并集 —— 没有接缝，也不用处理抗锯齿。
///
/// 观感差异：z_math 的笔迹**圆润、无尖角笔锋**，起笔固定 0.4、收笔收到 0.1 出锋，
/// 粗细完全由**书写速度**驱动（快则细、慢则粗），不依赖压感硬件。
/// 因此它特别适合手指 / 鼠标 / 触控屏这些没有真实压感的输入 —— 这是它叫
/// 「智能」钢笔的原因：不需要压感也能写出有粗细变化的字。
class ZMath {
  // —— 原版常数（尽量保持与 z_math.js 一致）——
  /// 参考采样间距(px)：等间隔采样的前提下「点间距 ∝ 速度」，故可直接用它当速度。
  /// 取值 8 对应 z_math.js 里 16ms 一帧移动 8px（s = 8/16 = 0.5 → w = 0.75）。
  static const double refStep = 8.0;

  /// 归一化宽度上限 / 下限（原版的 arr.maxwidth / minwidth，原版存了却没用上，这里补上）。
  static const double maxW = 1.0;
  static const double minW = 0.05;

  /// 中点二次贝塞尔的细分步数（原版固定 10）。
  static const int bezierSteps = 10;

  /// 圆点间距 = 半径 × 该比例（原版 0.45）。越小越密越平滑，代价是圆点数量。
  static const double dotSpacingRatio = 0.45;

  /// 单笔圆点数量硬上限：极端长笔画（几千个采样点）时按比例放大间距，
  /// 否则一次 fill 几万个 oval 会明显掉帧。
  static const int maxDots = 1600;

  /// 起笔宽度（原版固定 0.4，不收头）与收笔宽度（原版收到 0.1 出笔锋）。
  static const double headW = 0.4;
  static const double tailW = 0.1;

  /// 每点宽度最大变化量（绝对量，归一化宽度）。
  ///
  /// **这里改了原版。** 原版写的是 `max_dif = 距离 × step`（step=0.05 或 0.2），
  /// 限速量与本段长度成正比：快速划一下 d 轻松超过 20px，此时 max_dif > 1，
  /// 而归一化宽度整段取值空间才 [0.05, 1] —— 限速**形同虚设**，宽度照样跳变，
  /// 屏幕上就是粗细突变的一节节「竹节」。改成绝对量后限速才真正生效。
  static const double rateLimit = 0.12;

  /// 计算一笔的**归一化宽度序列**（0..1），逐点对应输入 [pts]。
  ///
  /// 三步：速度→宽度映射 → 限速 → 与上一个宽度取平均（原版的二级平滑）。
  static List<double> _widths(List<Point> pts) {
    final n = pts.length;
    final w = List<double>.filled(n, 0.5);
    var last = 0.5;
    for (var i = 0; i < n; i++) {
      double cur;
      if (i == 0) {
        cur = headW; // 起笔固定 0.4，不收头（原版语义）
      } else {
        final dx = pts[i].x - pts[i - 1].x;
        final dy = pts[i].y - pts[i - 1].y;
        final d = math.sqrt(dx * dx + dy * dy);
        final s = d / refStep; // 归一化速度
        // 核心映射：快 → 细，慢 → 粗
        cur = ((2.0 - s) / 2.0).clamp(minW, maxW);
        // 限速：不让宽度在相邻两点间跳变
        final dif = cur - last;
        if (dif.abs() > rateLimit) {
          cur = last + (dif > 0 ? rateLimit : -rateLimit);
        }
      }
      // 与上一个宽度取平均 —— 原版的第二层平滑，进一步抹掉抖动
      cur = (cur + last) / 2;
      cur = cur.clamp(minW, maxW);
      w[i] = cur;
      last = cur;
    }
    if (n >= 2) w[n - 1] = tailW; // 收笔出锋
    return w;
  }

  /// 中点二次贝塞尔平滑 + 位置/宽度同步插值。
  ///
  /// 控制点 = 上一个原始输入点，终点 = 相邻两原始点的中点，固定 [bezierSteps] 步展开。
  ///
  /// **这里也改了原版。** 原版只插值**位置**，宽度靠随后的
  /// `z_fpoint_differential_add` 按 `|Δw|/0.1` 再细分一遍插值来补连续性。
  /// 我们把宽度放进同一条贝塞尔里插值，宽度天生连续（宽度也是三次曲线），
  /// 那一步差分细分就成了纯冗余 —— 它会把点数再翻一倍。故此处直接省掉。
  static void _smoothInto(
    List<Point> pts,
    List<double> ws,
    List<double> ox,
    List<double> oy,
    List<double> ow,
  ) {
    final n = pts.length;
    ox.add(pts[0].x);
    oy.add(pts[0].y);
    ow.add(ws[0]);
    if (n < 2) return;
    for (var i = 1; i < n; i++) {
      final p0 = pts[i - 1]; // 控制点 = 上一个原始点
      final p1 = pts[i];
      final mx = (p0.x + p1.x) / 2; // 终点 = 中点
      final my = (p0.y + p1.y) / 2;
      final mw = (ws[i - 1] + ws[i]) / 2;
      final w0 = ws[i - 1], w1 = ws[i];
      for (var s = 1; s <= bezierSteps; s++) {
        final t = s / bezierSteps;
        final it = 1 - t;
        // 二次贝塞尔：B(t) = (1-t)²P0 + 2t(1-t)C + t²P1
        final a = it * it, b = 2 * t * it, c = t * t;
        ox.add(a * p0.x + b * p0.x + c * mx);
        oy.add(a * p0.y + b * p0.y + c * my);
        ow.add(a * w0 + b * w0 + c * mw);
      }
    }
  }

  /// 渲染用的中间结果：平滑后的中心线 + 逐点半径。
  static _Profile _profile(Stroke s) {
    final pts = s.points;
    final ws = _widths(pts);
    final ox = <double>[];
    final oy = <double>[];
    final ow = <double>[];
    _smoothInto(pts, ws, ox, oy, ow);
    final half = (s.size / 2.0).clamp(0.3, 100000.0);
    final radii = <double>[
      for (final w in ow) (w * half).clamp(0.45, half * 1.5),
    ];
    return _Profile(ox, oy, radii);
  }

  /// 把一笔 Stroke 转成**可填充**路径：沿中心线盖一串圆点的并集。
  static ui.Path buildPath(Stroke stroke) {
    if (stroke.points.isEmpty) return ui.Path();
    final p = _profile(stroke);
    final path = ui.Path();
    _addDots(path, p);
    return path;
  }

  /// 沿中心线按弧长步进盖圆点。首尾各强制放一个（保证端头是圆的）。
  static void _addDots(ui.Path path, _Profile p) {
    final n = p.x.length;
    if (n == 1) {
      path.addOval(ui.Rect.fromCircle(
          center: ui.Offset(p.x[0], p.y[0]), radius: p.r[0]));
      return;
    }
    // 先按 45% 半径估一遍圆点数，超限则整体放大间距（宁可略糙也不能掉帧）
    var total = 0.0;
    for (var i = 1; i < n; i++) {
      total += math.sqrt(math.pow(p.x[i] - p.x[i - 1], 2) +
          math.pow(p.y[i] - p.y[i - 1], 2));
    }
    final avgR = p.r.reduce((a, b) => a + b) / n;
    var spacing = (avgR * dotSpacingRatio).clamp(0.35, 10000.0);
    final est = total / spacing;
    if (est > maxDots) spacing = total / maxDots;

    path.addOval(ui.Rect.fromCircle(
        center: ui.Offset(p.x[0], p.y[0]), radius: p.r[0]));
    var acc = 0.0;
    for (var i = 1; i < n; i++) {
      final dx = p.x[i] - p.x[i - 1];
      final dy = p.y[i] - p.y[i - 1];
      acc += math.sqrt(dx * dx + dy * dy);
      if (acc >= spacing) {
        acc = 0.0;
        path.addOval(ui.Rect.fromCircle(
            center: ui.Offset(p.x[i], p.y[i]), radius: p.r[i]));
      }
    }
    path.addOval(ui.Rect.fromCircle(
        center: ui.Offset(p.x[n - 1], p.y[n - 1]), radius: p.r[n - 1]));
  }

  /// 平滑后的中心线 + 半径（页面坐标）。供 PDF 矢量导出复用，
  /// 保证导出与屏幕所见同源。
  static List<_Seg> segments(Stroke s) {
    final p = _profile(s);
    final out = <_Seg>[];
    for (var i = 0; i < p.x.length; i++) {
      out.add(_Seg(ui.Offset(p.x[i], p.y[i]), p.r[i]));
    }
    return out;
  }
}

/// 平滑后的中心线点 + 该点半径。
class _Profile {
  final List<double> x;
  final List<double> y;
  final List<double> r;
  _Profile(this.x, this.y, this.r);
}

/// PDF 导出用的一段：中心点 + 半径。
class _Seg {
  final ui.Offset p;
  final double r;
  const _Seg(this.p, this.r);
}

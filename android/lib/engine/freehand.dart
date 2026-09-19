import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:perfect_freehand/perfect_freehand.dart' as pf;
import 'package:flutter/material.dart';

import '../models/point.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../theme.dart';
import 'z_math.dart';

/// 笔迹美化引擎：封装 perfect_freehand 的 getStroke（平滑 + 压力笔宽 + 锥形收笔 + 圆头），
/// 输出可填充的 Path。对标 Kotlin 版 Freehand.kt 与 GoodNotes 压感/笔尖锐度/平滑管线。
class Freehand {
  // —— 压感管线基准（运行时从 AppSettings 读取，这里仅作兜底默认值）——
  static const double _refSpeed = 14.0; // 参考采样间距(px)：小于它=慢(粗)，大于它=快(细)
  static const double _dampSpeed = 0.40; // 速度信号 EMA 阻尼（先平滑点间距抖动）

  /// 压感配置快照（从 AppSettings 读取，避免每次渲染重复取字段）。
  static _PressureCfg _cfg() {
    final s = AppSettings.instance;
    return _PressureCfg(
      enabled: s.usePressure,
      penPressure: s.penPressure,
      brushPressure: s.brushPressure,
      offset: s.pressureOffset,
      damping: s.pressureDamping,
      estimation: s.pressureEstimation,
      tipSharpness: s.tipSharpness,
      penSens: s.penSensitivity,
      brushSens: s.brushSensitivity,
      smoothing: s.lineSmoothing,
      curveSmooth: s.curveSmoothing,
    );
  }

  /// 压感管线（对标 GoodNotes 压感三件套 + Notein 速度模拟）：
  /// 1) pressureEstimation：无真实压感（手指/鼠标/导入旧数据统一 0.5）时由相邻点间距(速度)
  ///    估算笔压——慢→粗、快→细；
  /// 2) pressureDamping：速度信号与笔压各做一层指数滑动平均(EMA)，彻底滤掉采样抖动；
  /// 3) pressureOffset：设笔压基线，最快处仍保留一定粗细；
  /// 4) pen/brush 独立压感开关 + 各自灵敏度(pressure_sensitivity_fountain / _brush)；
  /// 5) tipSharpness：笔尖锐度，越大端点收得越尖、宽度对比越强。
  /// 仅影响渲染路径，不改存储数据。
  static List<Point> _refine(List<Point> src, _BrushConfig cfg) {
    if (src.length < 2) return src;
    final tool = cfg.tool;
    final pressOn = cfg.enabled &&
        (tool == Tool.brush
            ? cfg.brushPressure
            : (tool.isPenLike ? cfg.penPressure : false));
    // 判断输入是否已携带有效压感变化
    var pmin = src[0].pressure, pmax = src[0].pressure;
    for (final s in src) {
      if (s.pressure < pmin) pmin = s.pressure;
      if (s.pressure > pmax) pmax = s.pressure;
    }
    final hasPressure = (pmax - pmin) > 0.02;
    final sens = tool == Tool.brush ? cfg.brushSens : cfg.penSens;

    final out = <Point>[];
    double spd = 0.0; // 平滑后的速度信号（点间距）
    double pr = 0.5; // 平滑后的笔压
    for (var i = 0; i < src.length; i++) {
      double p;
      if (pressOn && hasPressure) {
        p = src[i].pressure; // 真压感/已估算压感：仅做阻尼
      } else if (pressOn) {
        // 由速度估算笔压：先对点间距做 EMA 抑制抖动
        double d = 0.0;
        if (i > 0) {
          final dx = src[i].x - src[i - 1].x;
          final dy = src[i].y - src[i - 1].y;
          d = math.sqrt(dx * dx + dy * dy);
        }
        spd = spd + (d - spd) * _dampSpeed;
        final speed = (spd / _refSpeed).clamp(0.0, 1.0); // 0=慢 1=快
        p = cfg.pressureOffset + (1.0 - speed) * cfg.pressureEstimation; // 慢→粗
      } else {
        p = 0.5; // 压感关闭：恒定笔宽
      }
      pr = pr + (p - pr) * cfg.pressureDamping; // pressureDamping
      // 灵敏度：以 0.5 为中点缩放（>1 更夸张，<1 更平）
      pr = (0.5 + (pr - 0.5) * sens).clamp(0.05, 1.0);
      out.add(Point(src[i].x, src[i].y, pr));
    }

    // 笔尖锐度：端点收尖（让笔锋更利落），仅对书写笔生效
    // 铅笔/矢量笔为硬边均匀线，不做锥度收尖
    if (tool.isPenLike &&
        cfg.tipSharpness > 0.05 &&
        out.length >= 3 &&
        tool != Tool.highlighter &&
        tool != Tool.laser &&
        tool != Tool.tape &&
        tool != Tool.pencil &&
        tool != Tool.vector &&
        tool != Tool.smartPen) {
      final taper = cfg.tipSharpness * 0.45;
      out[0] = Point(out[0].x, out[0].y,
          (out[0].pressure * (1 - taper)).clamp(0.02, 1.0));
      out[out.length - 1] = Point(out[out.length - 1].x, out[out.length - 1].y,
          (out[out.length - 1].pressure * (1 - taper)).clamp(0.02, 1.0));
    }
    return out;
  }

  /// thinning（压感→笔宽对比）：钢笔/画笔为正向（压重=粗）；荧光/胶带/激光/矢量=0（恒定宽度）。
  /// 铅笔略低于钢笔（石墨感更硬）；彩虹笔同钢笔。tipSharpness 提升对比，笔锋更锐利。
  static double _thinningFor(Tool tool, double tip) {
    final base = tool == Tool.brush
        ? 0.78
        : (tool == Tool.highlighter ||
                tool == Tool.laser ||
                tool == Tool.tape ||
                tool == Tool.vector)
            ? 0.0
            : (tool == Tool.pencil ? 0.55 : 0.65);
    return (base * (0.45 + tip * 0.9)).clamp(0.0, 1.0);
  }

  /// 把一笔 Stroke 转成填充路径。
  static Path buildPath(Stroke stroke) {
    if (stroke.points.isEmpty) return Path();

    // 形状笔画走几何绘制，不走 freehand
    if (stroke.isShape) return _shapePath(stroke);
    // 智能钢笔走 z_math（沿中心线盖圆点），与 perfect_freehand 是两条独立管线
    if (stroke.tool == Tool.smartPen) return ZMath.buildPath(stroke);

    final cfg = _resolve(stroke); // 结合全局设置 + stroke.meta['brush']（自定义画笔覆盖）
    final refined = _refine(stroke.points, cfg);

    // 曲线平滑（stylus_option_line_smoothing）：折线点→Catmull-Rom 三次贝塞尔拟合后重采样，
    // 消除高速书写的折角；不开启则直接走 refined 原始点（perfect_freehand 仍有基础平滑）。
    final pts = (cfg.smoothing && stroke.tool.isPenLike)
        ? CurveFitter.fit(refined, curveSmooth: cfg.curveSmooth)
        : refined;

    final inputPoints = pts
        .map((p) => pf.Point(p.x, p.y, p.pressure))
        .toList();

    final thinning = cfg.thinning;
    final flat = stroke.meta != null && stroke.meta!['flat'] == true;
    final options = pf.StrokeOptions(
      size: stroke.size,
      thinning: thinning,
      smoothing: (0.5 + cfg.curveSmooth * 0.4).clamp(0.0, 1.0),
      streamline: 0.5,
      simulatePressure: false, // 关键：用上面管线的压感，绝不让 perfect_freehand 自己用原始速度
    );
    // 荧光笔平头：关闭两端圆角（perfect_freehand 的 flat tip = 方头）
    if (flat) {
      options.start = pf.StrokeEndOptions.start(cap: false);
      options.end = pf.StrokeEndOptions.end(cap: false);
    }

    final outline = pf.getStroke(inputPoints, options: options);
    if (outline.isEmpty) return Path();

    final path = Path();
    path.moveTo(outline.first.dx, outline.first.dy);
    for (var i = 1; i < outline.length; i++) {
      final p0 = outline[i - 1];
      final p1 = outline[i];
      path.quadraticBezierTo(
          p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
    }
    path.close();
    return path;
  }

  /// 返回一笔的填充轮廓点（页面坐标，与屏幕渲染同源）。
  /// 非形状笔迹 = perfect_freehand outline 多边形；形状笔迹导出走 [_paintShape] 不依赖此方法。
  /// 供 PDF 矢量导出复用，保证笔迹轮廓与屏幕所见一致。
  static List<Offset> outlinePoints(Stroke stroke) {
    if (stroke.points.isEmpty) return const [];
    if (stroke.isShape) return const [];

    final cfg = _resolve(stroke);
    final refined = _refine(stroke.points, cfg);
    final pts = (cfg.smoothing && stroke.tool.isPenLike)
        ? CurveFitter.fit(refined, curveSmooth: cfg.curveSmooth)
        : refined;

    final inputPoints = pts
        .map((p) => pf.Point(p.x, p.y, p.pressure))
        .toList();

    final thinning = cfg.thinning;
    final flat = stroke.meta != null && stroke.meta!['flat'] == true;
    final options = pf.StrokeOptions(
      size: stroke.size,
      thinning: thinning,
      smoothing: (0.5 + cfg.curveSmooth * 0.4).clamp(0.0, 1.0),
      streamline: 0.5,
      simulatePressure: false,
    );
    if (flat) {
      options.start = pf.StrokeEndOptions.start(cap: false);
      options.end = pf.StrokeEndOptions.end(cap: false);
    }

    final outline = pf.getStroke(inputPoints, options: options);
    return outline.map((p) => Offset(p.dx, p.dy)).toList();
  }

  /// 彩虹笔中心线：返回经过压感管线 + 曲线平滑后的中心折线（不含 perfect_freehand 轮廓）。
  /// 渲染层用它按累计弧长做色相循环着色（单色填充路径无法表达沿笔迹的渐变）。
  static List<Offset> centerline(Stroke stroke) {
    final cfg = _resolve(stroke);
    final refined = _refine(stroke.points, cfg);
    final pts = (cfg.smoothing && stroke.tool.isPenLike)
        ? CurveFitter.fit(refined, curveSmooth: cfg.curveSmooth)
        : refined;
    return pts.map((p) => Offset(p.x, p.y)).toList();
  }

  /// 解析一笔的实际渲染配置：以全局设置(AutoSettings)为默认，若 stroke.meta['brush']
  /// 携带自定义画笔烘焙参数（thin/tip/smooth/curve/p:{on,off,damp,est,sens}）则覆盖之。
  /// 非自定义笔（meta 无 'brush'）行为完全等同于旧版全局配置，向后兼容。
  static _BrushConfig _resolve(Stroke s) {
    final g = _cfg();
    double thin = _thinningFor(s.tool, g.tipSharpness);
    double tip = g.tipSharpness;
    bool smooth = g.smoothing;
    double curve = g.curveSmooth;
    double off = g.offset;
    double damp = g.damping;
    double est = g.estimation;
    double sens = s.tool == Tool.brush ? g.brushSens : g.penSens;
    bool enabled = g.enabled;
    final b = s.meta?['brush'];
    if (b is Map<String, dynamic>) {
      if (b['thin'] is num) thin = (b['thin'] as num).toDouble();
      if (b['tip'] is num) tip = (b['tip'] as num).toDouble();
      if (b['smooth'] is bool) smooth = b['smooth'] as bool;
      if (b['curve'] is num) curve = (b['curve'] as num).toDouble();
      final p = b['p'];
      if (p is Map) {
        if (p['off'] is num) off = (p['off'] as num).toDouble();
        if (p['damp'] is num) damp = (p['damp'] as num).toDouble();
        if (p['est'] is num) est = (p['est'] as num).toDouble();
        if (p['sens'] is num) sens = (p['sens'] as num).toDouble();
        if (p['on'] is bool) enabled = p['on'] as bool;
      }
    }
    return _BrushConfig(
      tool: s.tool,
      thinning: thin,
      tipSharpness: tip,
      smoothing: smooth,
      curveSmooth: curve,
      pressureOffset: off,
      pressureDamping: damp,
      pressureEstimation: est,
      penSens: sens,
      brushSens: sens,
      enabled: enabled,
      penPressure: g.penPressure,
      brushPressure: g.brushPressure,
    );
  }

  /// 跟手预测曲线（prediction curve）：基于最近两段速度外推 1~2 帧，
  /// 补偿触控采样延迟，让笔迹「跟手」。仅用于实时预览，不写入存储。
  static List<Point> predict(List<Point> pts) {
    if (pts.length < 3) return pts;
    final n = pts.length;
    final v1x = pts[n - 1].x - pts[n - 2].x;
    final v1y = pts[n - 1].y - pts[n - 2].y;
    final v2x = pts[n - 2].x - pts[n - 3].x;
    final v2y = pts[n - 2].y - pts[n - 3].y;
    final vx = (v1x + v2x) / 2;
    final vy = (v1y + v2y) / 2;
    if (math.sqrt(vx * vx + vy * vy) < 0.5) return pts; // 基本静止不预测
    const k = 1.6; // 外推帧数
    final px = pts[n - 1].x + vx * k;
    final py = pts[n - 1].y + vy * k;
    return List<Point>.from(pts)
      ..add(Point(px, py, pts[n - 1].pressure));
  }

  /// 形状工具把「原始采样点」规整成「几何控制点」。
  ///
  /// 为什么必须做这一步：形状工具拖拽时存的是几十上百个连续采样点，
  /// 而 [_shapePath] 的约定是「规整控制点」（rect 取 points[0..3]、triangle 取
  /// points[0..2]）。若直接把采样点喂进去，取到的是起点附近挤成一团的几个点，
  /// 画出的是退化到几乎不可见的小多边形 —— 这就是矩形/三角形"画不出来"的根因。
  ///
  /// 收敛成规范控制点后，渲染 / PDF 导出 / 光栅导出 / 选中缩放旋转 全部统一受益。
  ///
  /// 注意：**不要**对 ShapeRecognizer 已规整好的点再调用本函数
  /// （会把 4 点旋转矩形压成 2 点）。调用方需自行区分来源。
  static List<Point> regularizeShape(Tool tool, List<Point> pts) {
    if (pts.length < 2) return pts;
    final a = pts.first;
    final b = pts.last;
    switch (tool) {
      case Tool.line:
      case Tool.arrow:
      case Tool.ellipse:
      case Tool.rect:
        // 均由「首尾两点」定义端点或包围盒
        return [a, b];
      case Tool.triangle:
        // 拖出的是包围盒内接等腰三角形：底边水平在下，顶点在上边中点
        // （对标 GoodNotes / Notability 的三角形工具语义）
        final x0 = math.min(a.x, b.x), x1 = math.max(a.x, b.x);
        final y0 = math.min(a.y, b.y), y1 = math.max(a.y, b.y);
        final cx = (x0 + x1) / 2;
        final p = b.pressure;
        return [
          Point(cx, y0, p), // 顶点（上中）
          Point(x1, y1, p), // 右下
          Point(x0, y1, p), // 左下
        ];
      default:
        return pts;
    }
  }

  /// 旋转前把「无法表达旋转」的 2 点形状展开成显式轮廓点。
  ///
  /// 为什么需要：rect / ellipse 的 2 点形式是**包围盒对角**，隐含「轴对齐」前提。
  /// 旋转只变换控制点、不改变这个前提，于是按新两点画出的是另一个轴对齐形状 ——
  /// 实测后果：
  ///  - 正圆 120x120 转 45°：两个对角点转成水平相对，包围盒高度塌成 0，
  ///    圆直接消失（半轴 84.85 / 0.00）
  ///  - 椭圆 200x100 转 30°：半轴从 (100,50) 变成 (93.3, 61.6)
  ///  - 矩形 200x150 转 30°：面积从 30000 掉到 17280
  ///
  /// 展开后 rect 变 4 角、ellipse 变 N 个轮廓采样点，旋转/缩放即为逐点变换，
  /// 形状保持不变。（ellipse 取 36 点：半径 200 时多边形误差 < 0.8px，肉眼不可见）
  ///
  /// 只在**发生旋转时**调用；未旋转时保持 2 点紧凑形式，便于后续编辑。
  static List<Point> expandForRotation(Tool tool, List<Point> pts) {
    if (pts.length != 2) return pts;
    switch (tool) {
      case Tool.rect:
        return <Point>[
          Point(pts[0].x, pts[0].y, pts[0].pressure), // 左上
          Point(pts[1].x, pts[0].y, pts[0].pressure), // 右上
          Point(pts[1].x, pts[1].y, pts[1].pressure), // 右下
          Point(pts[0].x, pts[1].y, pts[0].pressure), // 左下
        ];
      case Tool.ellipse:
        final cx = (pts[0].x + pts[1].x) / 2, cy = (pts[0].y + pts[1].y) / 2;
        final rx = (pts[1].x - pts[0].x).abs() / 2;
        final ry = (pts[1].y - pts[0].y).abs() / 2;
        const n = 36;
        return <Point>[
          for (var i = 0; i < n; i++)
            Point(cx + rx * math.cos(2 * math.pi * i / n),
                cy + ry * math.sin(2 * math.pi * i / n), pts[0].pressure),
        ];
      default:
        return pts;
    }
  }

  /// 形状笔画的几何绘制。
  ///
  /// 控制点约定（与 ShapeRecognizer 输出一致）：
  ///  - line / arrow : 2 点，arrow 的 [1] 为箭头尖端
  ///  - rect         : 2 点（轴对齐对角）或 4 点（旋转矩形四角）
  ///  - ellipse      : 2 点（包围盒对角）或 N 点（旋转椭圆的轮廓采样）
  ///  - triangle     : 3 点（顶点）
  static Path _shapePath(Stroke s) {
    final path = Path();
    if (s.points.length < 2) return path;
    final a = s.points.first;
    final b = s.points.last;
    switch (s.tool) {
      case Tool.line:
        path.moveTo(a.x, a.y);
        path.lineTo(b.x, b.y);
        break;
      case Tool.rect:
        if (s.points.length >= 4) {
          // 旋转矩形：依次连接 4 个角点
          path.moveTo(s.points[0].x, s.points[0].y);
          for (var i = 1; i < 4; i++) {
            path.lineTo(s.points[i].x, s.points[i].y);
          }
          path.close();
        } else {
          path.addRect(Rect.fromPoints(Offset(a.x, a.y), Offset(b.x, b.y)));
        }
        break;
      case Tool.ellipse:
        if (s.points.length > 2) {
          // 旋转过的椭圆：控制点已是轮廓采样点，直接连成闭合多边形
          // （addOval 只能画轴对齐椭圆，表达不了旋转）
          path.moveTo(s.points[0].x, s.points[0].y);
          for (var i = 1; i < s.points.length; i++) {
            path.lineTo(s.points[i].x, s.points[i].y);
          }
          path.close();
        } else {
          path.addOval(Rect.fromPoints(Offset(a.x, a.y), Offset(b.x, b.y)));
        }
        break;
      case Tool.triangle:
        if (s.points.length >= 3) {
          path.moveTo(s.points[0].x, s.points[0].y);
          path.lineTo(s.points[1].x, s.points[1].y);
          path.lineTo(s.points[2].x, s.points[2].y);
          path.close();
        } else {
          path.addRect(Rect.fromPoints(Offset(a.x, a.y), Offset(b.x, b.y)));
        }
        break;
      case Tool.arrow:
        path.moveTo(a.x, a.y);
        path.lineTo(b.x, b.y);
        _addArrowHead(path, a, b, s.size);
        break;
      default:
        break;
    }
    return path;
  }

  /// 在箭头尖端 [tip] 处补上 V 形箭头头部（沿 tail→tip 方向）。
  static void _addArrowHead(Path path, Point tail, Point tip, double size) {
    final ang = math.atan2(tip.y - tail.y, tip.x - tail.x);
    final len = (size * 3.4).clamp(11.0, 40.0);
    const spread = 0.40; // ≈23°
    path.moveTo(tip.x - len * math.cos(ang - spread),
        tip.y - len * math.sin(ang - spread));
    path.lineTo(tip.x, tip.y);
    path.lineTo(tip.x - len * math.cos(ang + spread),
        tip.y - len * math.sin(ang + spread));
  }
}

/// 单笔解析后的渲染配置（全局设置 + 自定义画笔覆盖后的最终值）。
class _BrushConfig {
  final Tool tool;
  final double thinning;
  final double tipSharpness;
  final bool smoothing;
  final double curveSmooth;
  final double pressureOffset;
  final double pressureDamping;
  final double pressureEstimation;
  final double penSens;
  final double brushSens;
  final bool enabled;
  final bool penPressure;
  final bool brushPressure;
  const _BrushConfig({
    required this.tool,
    required this.thinning,
    required this.tipSharpness,
    required this.smoothing,
    required this.curveSmooth,
    required this.pressureOffset,
    required this.pressureDamping,
    required this.pressureEstimation,
    required this.penSens,
    required this.brushSens,
    required this.enabled,
    required this.penPressure,
    required this.brushPressure,
  });
}

/// 压感配置快照。
class _PressureCfg {
  final bool enabled;
  final bool penPressure;
  final bool brushPressure;
  final double offset;
  final double damping;
  final double estimation;
  final double tipSharpness;
  final double penSens;
  final double brushSens;
  final bool smoothing;
  final double curveSmooth;
  const _PressureCfg({
    required this.enabled,
    required this.penPressure,
    required this.brushPressure,
    required this.offset,
    required this.damping,
    required this.estimation,
    required this.tipSharpness,
    required this.penSens,
    required this.brushSens,
    required this.smoothing,
    required this.curveSmooth,
  });
}

/// 曲线拟合：折线点 → 分段三次 Catmull-Rom 插值后重采样为密集平滑折线。
///
/// 移植自 SpeedyNote `VectorLayer::catmullRomSubdivide`（其"笔记美化"核心算法）：
///  - 每段用相邻 4 点做**均匀 Catmull-Rom 插值**，位置与压感均走同一套三次公式，
///    因此笔宽过渡也连续顺滑（杜绝线性近似带来的粗细折角）；
///  - 端点切线用"复制首/末控制点"（零加速度边界），自然收尾；
///  - 压感钳制 [0.1, 1.0] 防过冲；每段插值点下限 4（CURVE_SUBDIVISIONS）。
///  - [curveSmooth] 仍控制采样密度上限（越大越密），输出折线交给 perfect_freehand 生成填充轮廓。
class CurveFitter {
  /// 每段最少插值点数——对齐 SpeedyNote 的 CURVE_SUBDIVISIONS = 4
  /// （4 段可保证 10x 缩放下每段 < 4px，肉眼无折线感）。
  static const int _minSubdiv = 4;

  /// [curveSmooth] 0..1，越大采样越密、曲线越顺。
  static List<Point> fit(List<Point> pts, {double curveSmooth = 0.6}) {
    if (pts.length < 3) return pts;
    final n = pts.length;
    final samples = ((_minSubdiv + curveSmooth * 10).round()).clamp(_minSubdiv, 16);
    final out = <Point>[];
    for (var i = 0; i < n - 1; i++) {
      // 四控制点：端点处复制自身，得到零加速度边界（与 SpeedyNote 一致）
      final p0 = pts[(i - 1).clamp(0, n - 1)];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = pts[(i + 2).clamp(0, n - 1)];
      if (i == 0) out.add(Point(p1.x, p1.y, p1.pressure));
      for (var s = 1; s <= samples; s++) {
        final t = s / samples;
        final t2 = t * t;
        final t3 = t2 * t;
        // 均匀 Catmull-Rom（位置）
        final x = 0.5 *
            ((2 * p1.x) +
                (-p0.x + p2.x) * t +
                (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3);
        final y = 0.5 *
            ((2 * p1.y) +
                (-p0.y + p2.y) * t +
                (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3);
        // 压感同样走三次 Catmull-Rom（SpeedyNote 的关键：笔宽不出现折角）
        final pr = 0.5 *
            ((2 * p1.pressure) +
                (-p0.pressure + p2.pressure) * t +
                (2 * p0.pressure - 5 * p1.pressure + 4 * p2.pressure - p3.pressure) * t2 +
                (-p0.pressure + 3 * p1.pressure - 3 * p2.pressure + p3.pressure) * t3);
        out.add(Point(x, y, pr.clamp(0.1, 1.0)));
      }
    }
    return out;
  }
}

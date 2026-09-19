import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Page;

import '../models/page.dart';
import '../models/content.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../engine/freehand.dart';
import '../theme.dart';

/// 把一页「背景模板 + 图片 + 文本框 + 笔迹（按可见图层）」完整光栅化成 ui.Image。
/// 供 PDF 导出 与 图片导出(PNG/JPG/WebP) 共用，保证所见即所得。
class PageRaster {
  final Page page;
  final bool eyeCare;
  /// 光栅化倍率（DPI 近似）。1.0 ≈ 72DPI（屏幕级，放大糊）；
  /// 导出 PDF 时传 3.0 ≈ 216DPI，放大明显更清晰。不影响矢量比例。
  final double scale;

  const PageRaster(this.page, {this.eyeCare = false, this.scale = 1.0});

  Future<ui.Image> rasterize() async {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    if (scale != 1.0) c.scale(scale, scale);
    final base = page.paperColor != null
        ? Color(page.paperColor!)
        : (eyeCare ? const Color(0xFFF5ECD7) : Colors.white);
    c.drawRect(
        Rect.fromLTWH(0, 0, page.width, page.height), Paint()..color = base);
    // 导入 PDF 渲染出的背景图（page.bgPath）。此前两条导出路径都漏了它，
    // 导致「导入 PDF 当底稿 → 导出」背景整块丢失，与屏幕不一致。
    if (page.bgPath != null) {
      try {
        final data = await File(page.bgPath!).readAsBytes();
        final codec = await ui.instantiateImageCodec(data);
        final fi = await codec.getNextFrame();
        c.drawImageRect(
          fi.image,
          Rect.fromLTWH(
              0, 0, fi.image.width.toDouble(), fi.image.height.toDouble()),
          Rect.fromLTWH(0, 0, page.width, page.height),
          Paint(),
        );
      } catch (_) {}
    }
    _template(c);

    // 图片
    for (final im in page.images) {
      try {
        final data = await File(im.path).readAsBytes();
        final codec = await ui.instantiateImageCodec(data);
        final fi = await codec.getNextFrame();
        final iw = fi.image.width.toDouble();
        final ih = fi.image.height.toDouble();
        final src = im.crop != null
            ? Rect.fromLTWH(
                (im.crop!['sx'] ?? 0) * iw,
                (im.crop!['sy'] ?? 0) * ih,
                (im.crop!['sw'] ?? 1) * iw,
                (im.crop!['sh'] ?? 1) * ih,
              )
            : Rect.fromLTWH(0, 0, iw, ih);
        c.drawImageRect(
          fi.image,
          src,
          Rect.fromLTWH(im.x, im.y, im.w, im.h),
          Paint(),
        );
      } catch (_) {}
    }

    // 文本框
    for (final tb in page.textBoxes) _text(c, tb);

    // 笔迹（仅可见图层）
    final visIds = {
      for (final l in page.layers.where((l) => l.visible)) l.id
    };
    for (final s in page.strokes.where((st) => visIds.contains(st.layerId))) {
      // 彩虹笔：屏幕上是沿弧长做色相循环，单色填充路径无法表达，必须逐段上色。
      // 与 _CanvasPainter._drawStroke 的彩虹分支同参数，保证导出与屏幕一致。
      if (s.tool == Tool.rainbow) {
        _rainbow(c, s);
        continue;
      }
      final path = Freehand.buildPath(s);
      final paint = Paint()
        ..color = Color(s.color).withOpacity(s.opacity)
        ..strokeWidth = s.size
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (s.isShape) {
        // 闭合形状填充：与屏幕渲染同源（设置项 fillShape / fillOpacity）
        final closed = s.tool == Tool.rect ||
            s.tool == Tool.ellipse ||
            s.tool == Tool.triangle;
        if (closed && AppSettings.instance.fillShape) {
          final fo =
              (s.opacity * AppSettings.instance.fillOpacity).clamp(0.0, 1.0);
          c.drawPath(
            path,
            Paint()
              ..color = Color(s.color).withOpacity(fo)
              ..style = PaintingStyle.fill,
          );
        }
        paint.style = PaintingStyle.stroke;
        c.drawPath(path, paint);
      } else {
        paint.style = PaintingStyle.fill;
        c.drawPath(path, paint);
      }
    }

    final pic = recorder.endRecording();
    return await pic.toImage(
      (page.width * scale).ceil(),
      (page.height * scale).ceil(),
    );
  }

  /// 彩虹笔：沿累计弧长做色相循环，逐段描线（round cap 保证段间平滑衔接）。
  void _rainbow(Canvas c, Stroke s) {
    final pts = Freehand.centerline(s);
    if (pts.length < 2) return;
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).distance;
    }
    var acc = 0.0;
    const cycles = 1.5;
    final paint = Paint()
      ..strokeWidth = s.size
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < pts.length; i++) {
      final seg = (pts[i] - pts[i - 1]).distance;
      acc += seg;
      final hue = total > 0 ? (acc / total * 360 * cycles) % 360 : 0.0;
      paint.color = HSVColor.fromAHSV(1.0, hue, 0.95, 1.0).toColor();
      c.drawLine(pts[i - 1], pts[i], paint);
    }
  }

  void _template(Canvas c) {
    if (page.template == PageTemplate.none) return;
    final lineColor =
        eyeCare ? const Color(0xFFD8C7A8) : const Color(0xFFE2E2E2);
    final paint = Paint()..color = lineColor..strokeWidth = 1.0;
    const step = 28.0;
    final w = page.width;
    final h = page.height;
    switch (page.template) {
      case PageTemplate.grid:
        for (double x = 0; x <= w; x += step) {
          c.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (double y = 0; y <= h; y += step) {
          c.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.line:
        for (double y = step; y <= h; y += step) {
          c.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.dot:
        for (double y = step; y <= h; y += step) {
          for (double x = step; x <= w; x += step) {
            c.drawCircle(Offset(x, y), 1.2, paint);
          }
        }
        break;
      case PageTemplate.cornell:
        // 康奈尔笔记：顶部标题 / 左侧提示栏 / 底部摘要区（与屏幕绘制同参数）
        c.drawLine(Offset(0, h * 0.13), Offset(w, h * 0.13), paint);
        c.drawLine(Offset(w * 0.28, h * 0.13), Offset(w * 0.28, h), paint);
        c.drawLine(Offset(0, h * 0.82), Offset(w, h * 0.82), paint);
        for (double y = h * 0.82 + step; y <= h; y += step) {
          c.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.week:
        const cols = 7;
        for (int i = 1; i < cols; i++) {
          final x = w * i / cols;
          c.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (double y = step; y <= h; y += step) {
          c.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        c.drawLine(Offset(0, step * 1.2), Offset(w, step * 1.2), paint);
        break;
      case PageTemplate.month:
        const cols = 7, rows = 6;
        final headH = step * 1.6;
        c.drawLine(Offset(0, headH), Offset(w, headH), paint);
        for (int i = 1; i < cols; i++) {
          final x = w * i / cols;
          c.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (int r = 1; r < rows; r++) {
          final y = headH + (h - headH) * r / rows;
          c.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.todos:
      case PageTemplate.checklist:
        for (double y = step; y <= h; y += step) {
          c.drawLine(Offset(step * 1.4, y), Offset(w, y), paint);
          c.drawRect(
            Rect.fromLTWH(8, y - step * 0.55, step * 0.7, step * 0.7),
            Paint()..color = lineColor..style = PaintingStyle.stroke..strokeWidth = 1,
          );
        }
        break;
      case PageTemplate.math:
        const g = 14.0;
        for (double x = 0; x <= w; x += g) {
          final heavy = ((x / g).round() % 5 == 0);
          c.drawLine(Offset(x, 0), Offset(x, h),
              heavy ? paint : Paint()..color = lineColor..strokeWidth = 0.5);
        }
        for (double y = 0; y <= h; y += g) {
          final heavy = ((y / g).round() % 5 == 0);
          c.drawLine(Offset(0, y), Offset(w, y),
              heavy ? paint : Paint()..color = lineColor..strokeWidth = 0.5);
        }
        break;
      case PageTemplate.music:
        const staffGap = 9.0;
        const groupGap = staffGap * 7;
        for (double top = step; top < h - staffGap * 5; top += groupGap) {
          for (int i = 0; i < 5; i++) {
            final y = top + i * staffGap;
            c.drawLine(Offset(0, y), Offset(w, y), paint);
          }
        }
        break;
      case PageTemplate.column2:
      case PageTemplate.column3:
        final n = page.template == PageTemplate.column2 ? 2 : 3;
        for (int i = 1; i < n; i++) {
          final x = w * i / n;
          c.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (double y = step; y <= h; y += step) {
          c.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      default:
        break;
    }
  }

  void _text(Canvas c, TextBox tb) {
    final box = Rect.fromLTWH(tb.x, tb.y, tb.w, tb.h);
    if (tb.bg != null) {
      c.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(tb.radius)),
          Paint()..color = Color(tb.bg!));
    }
    if (tb.border != null) {
      c.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(tb.radius)),
        Paint()
          ..color = Color(tb.border!)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final tp = TextPainter(
      text: TextSpan(
        text: tb.text,
        style: TextStyle(
          color: Color(tb.color),
          fontSize: tb.fontSize,
          fontWeight: tb.bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: tb.align == 1
          ? TextAlign.center
          : tb.align == 2
          ? TextAlign.right
          : TextAlign.left,
    );
    tp.layout(maxWidth: tb.w);
    final off = tb.align == 1
        ? Offset(tb.x + (tb.w - tp.width) / 2, tb.y)
        : tb.align == 2
        ? Offset(tb.x + (tb.w - tp.width), tb.y)
        : Offset(tb.x, tb.y);
    tp.paint(c, off);
  }
}

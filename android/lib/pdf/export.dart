import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../engine/freehand.dart';
import '../engine/z_math.dart';
import '../models/content.dart';
import '../models/note.dart';
import '../models/page.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../render/page_raster.dart';
import '../theme.dart';

/// 导出整本笔记为 **矢量 PDF**（完全离线）：
///  - 笔迹 / 手绘图形 / 模板 / 纸张背景 = PDF 矢量图元，放大任意倍清晰；
///  - 文本框 = 嵌入中文字体后矢量绘制；
///  - 导入的图片 = 仍作为位图 XObject 嵌入（图片本质即位图，无法矢量）。
class PdfExport {
  /// 嵌入的中文字体资源路径（运行时子集化，仅把用到的字形写进 PDF）。
  static const String _fontAsset = 'assets/fonts/NotoSansSC-subset.otf';

  /// 直接生成矢量 PDF 字节（供「分享」用，不落盘）。
  static Future<Uint8List> exportBytes(Note note, {bool eyeCare = false}) async {
    final ttfData = await rootBundle.load(_fontAsset);
    final ttf = pw.Font.ttf(ttfData);

    final pdf = pw.Document();
    for (final page in note.pages) {
      // 预读图片字节（build 回调是同步的）
      final imgBytes = <NoteImage, Uint8List>{};
      for (final im in page.images) {
        try {
          imgBytes[im] = await File(im.path).readAsBytes();
        } catch (_) {}
      }
      // 预读背景图（导入 PDF 渲染出的底稿）
      Uint8List? bgBytes;
      if (page.bgPath != null) {
        try {
          bgBytes = await File(page.bgPath!).readAsBytes();
        } catch (_) {}
      }

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(page.width, page.height),
          build: (_) => pw.Stack(
            children: [
              // 1) 背景 + 模板（矢量，最底层）
              pw.Positioned.fill(
                child: pw.CustomPaint(
                  painter: (g, _) => _paintBackground(g, page, eyeCare),
                ),
              ),
              // 1.5) 导入 PDF 的底稿背景图（此前导出时会整块丢失）
              if (bgBytes != null)
                pw.Positioned.fill(
                  child: pw.Image(pw.MemoryImage(bgBytes!),
                      fit: pw.BoxFit.fill),
                ),
              // 2) 图片（位图 XObject）
              for (final im in page.images)
                if (imgBytes.containsKey(im))
                  pw.Positioned(
                    left: im.x,
                    top: im.y,
                    child: pw.SizedBox(
                      width: im.w,
                      height: im.h,
                      child: pw.Image(pw.MemoryImage(imgBytes[im]!),
                          fit: pw.BoxFit.fill),
                    ),
                  ),
              // 3) 文本框（嵌入中文字体矢量绘制）
              for (final tb in page.textBoxes)
                pw.Positioned(
                  left: tb.x,
                  top: tb.y,
                  child: pw.SizedBox(
                    width: tb.w,
                    height: tb.h,
                    child: _textWidget(tb, ttf),
                  ),
                ),
              // 4) 笔迹 / 手绘图形（矢量，最上层）
              pw.Positioned.fill(
                child: pw.CustomPaint(
                  painter: (g, _) => _paintStrokes(g, page),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return await pdf.save();
  }

  static Future<String> export(Note note, String outPath,
      {bool eyeCare = false}) async {
    final file = File(outPath);
    await file.writeAsBytes(await exportBytes(note, eyeCare: eyeCare));
    return outPath;
  }

  // ---- 矢量绘制辅助 ----

  /// ARGB int + 透明度 -> PDF 颜色（alpha 0..1）。
  static PdfColor _pc(int argb, double opacity) {
    final c = Color(argb);
    return PdfColor(
      c.red / 255,
      c.green / 255,
      c.blue / 255,
      (c.alpha / 255) * opacity,
    );
  }

  /// Flutter(y 向下) -> PDF(y 向上)。
  static double _ty(Page page, double fy) => page.height - fy;

  static void _paintBackground(PdfGraphics g, Page page, bool eyeCare) {
    final base = page.paperColor != null
        ? Color(page.paperColor!)
        : (eyeCare ? const Color(0xFFF5ECD7) : Colors.white);
    g.setFillColor(_pc(base.value, 1));
    g.drawRect(0, 0, page.width, page.height);
    g.fillPath();
    _paintTemplate(g, page, eyeCare);
  }

  static void _paintTemplate(PdfGraphics g, Page page, bool eyeCare) {
    if (page.template == PageTemplate.none) return;
    final lineColor =
        eyeCare ? const Color(0xFFD8C7A8) : const Color(0xFFE2E2E2);
    g.setStrokeColor(_pc(lineColor.value, 1));
    g.setLineWidth(1.0);
    const step = 28.0;
    final w = page.width;
    final h = page.height;
    final ty = (double y) => h - y;
    switch (page.template) {
      case PageTemplate.grid:
        for (double x = 0; x <= w; x += step) {
          g.moveTo(x, 0);
          g.lineTo(x, h);
          g.strokePath();
        }
        for (double y = 0; y <= h; y += step) {
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
        }
        break;
      case PageTemplate.line:
        for (double y = step; y <= h; y += step) {
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
        }
        break;
      case PageTemplate.dot:
        for (double y = step; y <= h; y += step) {
          for (double x = step; x <= w; x += step) {
            g.drawEllipse(x, ty(y), 1.2, 1.2);
            g.strokePath();
          }
        }
        break;
      case PageTemplate.cornell:
        // 康奈尔笔记：顶部标题 / 左侧提示栏 / 底部摘要区（与屏幕绘制同参数）
        g.moveTo(0, ty(h * 0.13));
        g.lineTo(w, ty(h * 0.13));
        g.strokePath();
        g.moveTo(w * 0.28, ty(h * 0.13));
        g.lineTo(w * 0.28, ty(h));
        g.strokePath();
        g.moveTo(0, ty(h * 0.82));
        g.lineTo(w, ty(h * 0.82));
        g.strokePath();
        for (double y = h * 0.82 + step; y <= h; y += step) {
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
        }
        break;
      case PageTemplate.week:
        const cols = 7;
        for (int i = 1; i < cols; i++) {
          final x = w * i / cols;
          g.moveTo(x, 0);
          g.lineTo(x, h);
          g.strokePath();
        }
        for (double y = step; y <= h; y += step) {
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
        }
        g.moveTo(0, ty(step * 1.2));
        g.lineTo(w, ty(step * 1.2));
        g.strokePath();
        break;
      case PageTemplate.month:
        const cols = 7, rows = 6;
        final headH = step * 1.6;
        g.moveTo(0, ty(headH));
        g.lineTo(w, ty(headH));
        g.strokePath();
        for (int i = 1; i < cols; i++) {
          final x = w * i / cols;
          g.moveTo(x, 0);
          g.lineTo(x, h);
          g.strokePath();
        }
        for (int r = 1; r < rows; r++) {
          final y = headH + (h - headH) * r / rows;
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
        }
        break;
      case PageTemplate.todos:
      case PageTemplate.checklist:
        for (double y = step; y <= h; y += step) {
          g.moveTo(step * 1.4, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
          g.drawRect(8, ty(y) - step * 0.55, step * 0.7, step * 0.7);
          g.strokePath();
        }
        break;
      case PageTemplate.math:
        const grid = 14.0;
        for (double x = 0; x <= w; x += grid) {
          final heavy = ((x / grid).round() % 5 == 0);
          g.moveTo(x, 0);
          g.lineTo(x, h);
          if (heavy) {
            g.strokePath();
          } else {
            g.setLineWidth(0.5);
            g.strokePath();
            g.setLineWidth(1.0);
          }
        }
        for (double y = 0; y <= h; y += grid) {
          final heavy = ((y / grid).round() % 5 == 0);
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          if (heavy) {
            g.strokePath();
          } else {
            g.setLineWidth(0.5);
            g.strokePath();
            g.setLineWidth(1.0);
          }
        }
        break;
      case PageTemplate.music:
        const staffGap = 9.0;
        const groupGap = staffGap * 7;
        for (double top = step; top < h - staffGap * 5; top += groupGap) {
          for (int i = 0; i < 5; i++) {
            final y = top + i * staffGap;
            g.moveTo(0, ty(y));
            g.lineTo(w, ty(y));
            g.strokePath();
          }
        }
        break;
      case PageTemplate.column2:
      case PageTemplate.column3:
        final n = page.template == PageTemplate.column2 ? 2 : 3;
        for (int i = 1; i < n; i++) {
          final x = w * i / n;
          g.moveTo(x, 0);
          g.lineTo(x, h);
          g.strokePath();
        }
        for (double y = step; y <= h; y += step) {
          g.moveTo(0, ty(y));
          g.lineTo(w, ty(y));
          g.strokePath();
        }
        break;
      default:
        break;
    }
  }

  static void _paintStrokes(PdfGraphics g, Page page) {
    final visIds = {for (final l in page.layers.where((l) => l.visible)) l.id};
    for (final s in page.strokes.where((st) => visIds.contains(st.layerId))) {
      // 彩虹笔：屏幕上是沿弧长做色相循环，整笔一个颜色无法表达，必须逐段上色
      if (s.tool == Tool.rainbow) {
        _paintRainbow(g, s, page);
      } else if (s.tool == Tool.smartPen) {
        _paintSmartPen(g, s, page);
      } else if (s.isShape) {
        _paintShape(g, s, page);
      } else {
        final pts = Freehand.outlinePoints(s);
        if (pts.isEmpty) continue;
        g.setFillColor(_pc(s.color, s.opacity));
        g.moveTo(pts[0].dx, page.height - pts[0].dy);
        for (var i = 1; i < pts.length; i++) {
          g.lineTo(pts[i].dx, page.height - pts[i].dy);
        }
        g.closePath();
        g.fillPath();
      }
    }
  }

  /// 彩虹笔：沿累计弧长做色相循环（与屏幕渲染同参数）。
  ///
  /// 按色相分 24 桶累积子路径，最后每桶一次 fillPath —— 若每小段都 strokePath，
  /// 一笔画几百段会让 PDF 体积和生成耗时都失控。
  /// 每个小段两端各延长半个笔宽，用来盖住转角处的楔形缺口
  /// （等效于屏幕上的 round cap + round join；PDF 里逐段描线否则会露缝）。
  static void _paintRainbow(PdfGraphics g, Stroke s, Page page) {
    final pts = Freehand.centerline(s);
    if (pts.length < 2) return;
    var total = 0.0;
    final acc = <double>[0.0];
    for (var i = 1; i < pts.length; i++) {
      final d = (pts[i] - pts[i - 1]).distance;
      acc.add(acc[i - 1] + d);
      total += d;
    }
    if (total <= 0) return;
    const cycles = 1.5; // 整笔色相循环圈数（与屏幕一致）
    const buckets = 24;
    final half = (s.size.clamp(1.0, 2000.0)) / 2;
    final ty = (double y) => page.height - y;
    for (var b = 0; b < buckets; b++) {
      g.setFillColor(_hsv((b + 0.5) * 360.0 / buckets, 0.95, 1.0, s.opacity));
      var any = false;
      for (var i = 1; i < pts.length; i++) {
        final segHue = (acc[i] / total * 360 * cycles) % 360;
        if ((segHue * buckets / 360).floor() % buckets != b) continue;
        final p = pts[i - 1], q = pts[i];
        final dx = q.dx - p.dx, dy = q.dy - p.dy;
        final L = math.sqrt(dx * dx + dy * dy);
        if (L <= 0) continue;
        final ux = dx / L, uy = dy / L;
        final ax = p.dx - ux * half, ay = p.dy - uy * half;
        final bx = q.dx + ux * half, by = q.dy + uy * half;
        final nx = -uy * half, ny = ux * half;
        g.moveTo(ax + nx, ty(ay + ny));
        g.lineTo(bx + nx, ty(by + ny));
        g.lineTo(bx - nx, ty(by - ny));
        g.lineTo(ax - nx, ty(ay - ny));
        g.closePath();
        any = true;
      }
      if (any) g.fillPath();
    }
  }

  /// 智能钢笔（z_math）：宽度沿笔迹连续变化，PDF 里没有「变宽描边」这种图元，
  /// 这里退化为**分段折线 + 逐段 lineWidth** —— 宽度变化小时连续若干段共用一条
  /// 折线（一次 strokePath），只在累计宽度变化超过阈值时才断开另起一段。
  /// 这样既保住了粗细渐变，又把 PDF 里的路径条数压到可控范围内
  /// （若每段都 strokePath，一笔画两千段会让体积和生成耗时都失控）。
  static void _paintSmartPen(PdfGraphics g, Stroke s, Page page) {
    final segs = ZMath.segments(s);
    if (segs.length < 2) return;
    final ty = (double y) => page.height - y;
    g.setStrokeColor(_pc(s.color, s.opacity));
    const wTol = 0.15; // 线宽容差(pt)：超过才断开另起一段
    var curW = -1.0;
    var started = false;
    for (var i = 0; i < segs.length; i++) {
      final w = (segs[i].r * 2).clamp(0.3, 2000.0);
      final x = segs[i].p.dx, y = ty(segs[i].p.dy);
      if (!started) {
        g.setLineWidth(w);
        g.moveTo(x, y);
        curW = w;
        started = true;
      } else if ((w - curW).abs() > wTol) {
        g.strokePath(); // 收掉上一段
        g.setLineWidth(w);
        g.moveTo(x, y);
        curW = w;
      } else {
        g.lineTo(x, y);
      }
    }
    if (started) g.strokePath();
  }

  static PdfColor _hsv(double hue, double sat, double val, double opacity) {
    final c = HSVColor.fromAHSV(1.0, hue, sat, val).toColor();
    return PdfColor(c.red / 255, c.green / 255, c.blue / 255,
        (c.alpha / 255) * opacity);
  }

  static void _paintShape(PdfGraphics g, Stroke s, Page page) {
    final col = _pc(s.color, s.opacity);
    g.setStrokeColor(col);
    g.setLineWidth(s.size.clamp(1.0, 2000.0));
    final ty = (double y) => page.height - y;
    final pts = s.points;
    if (pts.length < 2) return;
    final a = pts.first;
    final b = pts.last;
    // 闭合形状填充：与屏幕渲染同源（设置项 fillShape / fillOpacity）
    final closed = s.tool == Tool.rect ||
        s.tool == Tool.ellipse ||
        s.tool == Tool.triangle;
    final fill = closed && AppSettings.instance.fillShape;
    if (fill) {
      final fo = (s.opacity * AppSettings.instance.fillOpacity).clamp(0.0, 1.0);
      g.setFillColor(_pc(s.color, fo));
    }
    switch (s.tool) {
      case Tool.line:
        g.moveTo(a.x, ty(a.y));
        g.lineTo(b.x, ty(b.y));
        g.strokePath();
        break;
      case Tool.rect:
        // 不复用 g.drawRect()：它内部已经把路径消费掉（fill+stroke 一次画完），
        // 后面再调 fillPath()/strokePath() 作用的是空路径 —— 填充色时有时无。
        // 改成与 4 点旋转矩形完全相同的显式路径写法，两种形态共用一套 fill/stroke。
        if (pts.length >= 4) {
          g.moveTo(pts[0].x, ty(pts[0].y));
          for (var i = 1; i < 4; i++) {
            g.lineTo(pts[i].x, ty(pts[i].y));
          }
        } else {
          final x0 = math.min(a.x, b.x), x1 = math.max(a.x, b.x);
          final y0 = math.min(a.y, b.y), y1 = math.max(a.y, b.y);
          // 注意 Y 轴翻转：屏幕向下为正，PDF 向上为正，四个角要各自换算
          g.moveTo(x0, ty(y0));
          g.lineTo(x1, ty(y0));
          g.lineTo(x1, ty(y1));
          g.lineTo(x0, ty(y1));
        }
        g.closePath();
        if (fill) g.fillPath();
        g.strokePath();
        break;
      case Tool.ellipse:
        if (pts.length > 2) {
          // 旋转过的椭圆：控制点已是轮廓采样点（drawEllipse 只能画轴对齐椭圆）
          g.moveTo(pts[0].x, ty(pts[0].y));
          for (var i = 1; i < pts.length; i++) {
            g.lineTo(pts[i].x, ty(pts[i].y));
          }
          g.closePath();
          if (fill) g.fillPath();
          g.strokePath();
        } else {
          g.drawEllipse(
            (a.x + b.x) / 2,
            ty((a.y + b.y) / 2),
            (b.x - a.x).abs() / 2,
            (a.y - b.y).abs() / 2,
          );
          if (fill) g.fillPath();
          g.strokePath();
        }
        break;
      case Tool.triangle:
        if (pts.length >= 3) {
          g.moveTo(pts[0].x, ty(pts[0].y));
          g.lineTo(pts[1].x, ty(pts[1].y));
          g.lineTo(pts[2].x, ty(pts[2].y));
          g.closePath();
          if (fill) g.fillPath();
          g.strokePath();
        }
        break;
      case Tool.arrow:
        g.moveTo(a.x, ty(a.y));
        g.lineTo(b.x, ty(b.y));
        g.strokePath();
        final ang = math.atan2(b.y - a.y, b.x - a.x);
        final len = (s.size * 3.4).clamp(11.0, 40.0);
        const spread = 0.40;
        g.moveTo(b.x - len * math.cos(ang - spread),
            ty(b.y - len * math.sin(ang - spread)));
        g.lineTo(b.x, ty(b.y));
        g.lineTo(b.x - len * math.cos(ang + spread),
            ty(b.y - len * math.sin(ang + spread)));
        g.strokePath();
        break;
      default:
        break;
    }
  }

  static pw.Widget _textWidget(TextBox tb, pw.Font ttf) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: tb.bg != null ? _pc(tb.bg!, 1) : null,
        border: tb.border != null
            ? pw.Border.all(width: 1.5, color: _pc(tb.border!, 1))
            : null,
        borderRadius:
            tb.radius > 0 ? pw.BorderRadius.circular(tb.radius) : null,
      ),
      child: pw.Text(
        tb.text,
        style: pw.TextStyle(
          font: ttf,
          fontSize: tb.fontSize,
          color: _pc(tb.color, 1),
          fontWeight: tb.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
        textAlign: tb.align == 1
            ? pw.TextAlign.center
            : tb.align == 2
            ? pw.TextAlign.right
            : pw.TextAlign.left,
      ),
    );
  }
}

/// 导出图片格式（光栅，保持原逻辑）。
///
/// 说明：Flutter 3.22 的 `ui.ImageByteFormat` 只有 png / rawRgba / rawUnmodified，
/// 没有 jpeg / webp，所以这里统一「先取 PNG，再用 image 包离线转码」。
/// WebP 编码（encodeWebP）在 image 包里暂不可用，故只支持 PNG / JPG。
enum ImageFormat { png, jpg }

extension ImageFormatX on ImageFormat {
  String get ext {
    switch (this) {
      case ImageFormat.png:
        return 'png';
      case ImageFormat.jpg:
        return 'jpg';
    }
  }
}

/// 导出当前页 / 整本为图片（PNG/JPG/WebP），完全离线。
class ImageExport {
  static Future<Uint8List> encode(ui.Image image, ImageFormat fmt) async {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    if (fmt == ImageFormat.png) return png;
    final decoded = img.decodePng(png);
    if (decoded == null) return png; // 兜底：解码失败就退回 PNG
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
  }

  static Future<String> exportPage(
    Note note,
    int index,
    ImageFormat fmt,
    String outPath, {
    bool eyeCare = false,
  }) async {
    final raster = await PageRaster(note.pages[index], eyeCare: eyeCare).rasterize();
    final bytes = await encode(raster, fmt);
    await File(outPath).writeAsBytes(bytes);
    raster.dispose();
    return outPath;
  }

  static Future<List<String>> exportAll(
    Note note,
    ImageFormat fmt,
    String outDir, {
    bool eyeCare = false,
  }) async {
    final out = <Future<String>>[];
    for (var i = 0; i < note.pages.length; i++) {
      out.add(exportPage(note, i, fmt, '$outDir/page_${i + 1}.${fmt.ext}',
          eyeCare: eyeCare));
    }
    return Future.wait(out);
  }
}

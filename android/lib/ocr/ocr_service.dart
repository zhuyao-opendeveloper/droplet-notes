import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Page;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../models/page.dart';
import '../engine/freehand.dart';
import '../render/page_raster.dart';

/// 单个识别块（一段文字 + 它在图上的包围盒）。
class OcrBlock {
  final String text;
  final Rect box;
  const OcrBlock(this.text, this.box);
}

/// 一次识别的完整结果。
class OcrResult {
  final String text;
  final List<OcrBlock> blocks;
  const OcrResult(this.text, this.blocks);

  bool get isEmpty => text.trim().isEmpty;
  int get charCount => text.replaceAll(RegExp(r'\s'), '').length;
}

/// 编译期开关：极速版（lite）用 `--dart-define=ENABLE_OCR=false` 关闭文字识别，
/// 从而彻底剔除 Google ML Kit 原生库（~10MB）与 bundled 模型（~1.5MB）。
const bool kEnableOcr =
    bool.fromEnvironment('ENABLE_OCR', defaultValue: true);

/// 文字识别服务。
///
/// 引擎：Google ML Kit Text Recognition v2（**bundled 模型**，随 APK 打包，
/// 运行时完全离线、不依赖 Google Play 服务，可免费商用）。
///
/// 能力定位（重要）：
/// - 擅长：PDF 扫描页、拍照/截图插图里的**印刷体**文字。
/// - 一般：**工整**手写（正楷、字距分明）。
/// - 较差：连笔／草书中文 —— 那属于「在线手写识别」（吃笔画轨迹）范畴，本引擎不做。
class OcrService {
  /// OCR 是否可用（极速版为 false，UI 据此隐藏文字识别入口）。
  static bool get available => kEnableOcr;

  /// 支持的识别语言（对应 ML Kit 的 script 模型）。
  static const scripts = <String, String>{
    'chinese': '中文（含英文数字）',
    'latin': '拉丁字母（英文等）',
    'japanese': '日文',
    'korean': '韩文',
  };

  static TextRecognitionScript _script(String name) {
    switch (name) {
      case 'latin':
        return TextRecognitionScript.latin;
      case 'japanese':
        return TextRecognitionScript.japanese;
      case 'korean':
        return TextRecognitionScript.korean;
      case 'chinese':
      default:
        return TextRecognitionScript.chinese;
    }
  }

  /// 识别本地图片文件。
  static Future<OcrResult> recognizeFile(
    String imagePath, {
    String script = 'chinese',
  }) async {
    if (!kEnableOcr) return OcrResult('', const []);
    final recognizer = TextRecognizer(script: _script(script));
    try {
      final input = InputImage.fromFilePath(imagePath);
      final r = await recognizer.processImage(input);
      final blocks = <OcrBlock>[
        for (final b in r.blocks) OcrBlock(b.text, b.boundingBox),
      ];
      return OcrResult(r.text, blocks);
    } finally {
      await recognizer.close();
    }
  }

  /// 识别整页（所见即所得：模板底纹 + 图片 + 文本框 + 笔迹）。
  static Future<OcrResult> recognizePage(
    Note note,
    int index, {
    String script = 'chinese',
    bool eyeCare = false,
    double scale = 2.0,
  }) async {
    if (!kEnableOcr) return OcrResult('', const []);
    final img = await PageRaster(note.pages[index], eyeCare: eyeCare).rasterize();
    final png = await _encode(img, scale);
    return _recognizeBytes(png, script);
  }

  /// 只识别手写笔迹（白底 + 笔迹，剔除模板横线/网格干扰）。
  /// 对手写内容的识别率通常明显高于整页识别。
  static Future<OcrResult> recognizeStrokes(
    Note note,
    int index, {
    String script = 'chinese',
    double scale = 2.5,
  }) async {
    if (!kEnableOcr) return OcrResult('', const []);
    final page = note.pages[index];
    final img = await _rasterStrokes(page);
    final png = await _encode(img, scale);
    return _recognizeBytes(png, script);
  }

  // ---------- 内部实现 ----------

  static Future<OcrResult> _recognizeBytes(Uint8List png, String script) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/ocr_${const Uuid().v4()}.png');
    await f.writeAsBytes(png);
    try {
      return await recognizeFile(f.path, script: script);
    } finally {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// 白底纯笔迹光栅化。
  static Future<ui.Image> _rasterStrokes(Page page) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, page.width, page.height),
        Paint()..color = Colors.white);
    final visIds = {for (final l in page.layers.where((l) => l.visible)) l.id};
    for (final s in page.strokes.where((st) => visIds.contains(st.layerId))) {
      final path = Freehand.buildPath(s);
      final paint = Paint()
        ..color = Colors.black // 统一成黑色，提高对比度
        ..strokeWidth = s.size
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = s.isShape ? PaintingStyle.stroke : PaintingStyle.fill;
      c.drawPath(path, paint);
    }
    return rec.endRecording().toImage(page.width.toInt(), page.height.toInt());
  }

  /// 放大后编码成 PNG（放大能显著提升小字识别率）。
  static Future<Uint8List> _encode(ui.Image src, double scale) async {
    ui.Image out = src;
    if (scale != 1.0) {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImageRect(
        src,
        Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        Rect.fromLTWH(0, 0, src.width * scale, src.height * scale),
        Paint()..filterQuality = FilterQuality.high,
      );
      out = await rec.endRecording().toImage(
            (src.width * scale).round(),
            (src.height * scale).round(),
          );
    }
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}

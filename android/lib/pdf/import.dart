import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:uuid/uuid.dart';

import '../models/page.dart';

/// PDF 导入：用 pdfx 把每页渲染为 PNG 背景图，逐页可书写。
class PdfImport {
  /// 单页背景图的最大边长。固定按 2x 渲染时，A3/海报尺寸或高 DPI 扫描页
  /// 单页 PNG 就能到十几 MB，几十页足以撑爆磁盘与内存。
  static const double maxSide = 2400.0;

  static Future<List<Page>> importToPages(String pdfPath,
      {String title = '导入的 PDF'}) async {
    final doc = await PdfDocument.openFile(pdfPath);
    final bgDir = Directory('${(await getApplicationDocumentsDirectory()).path}/bg');
    await bgDir.create(recursive: true);

    final pages = <Page>[];
    try {
      for (var i = 1; i <= doc.pagesCount; i++) {
        final pg = await doc.getPage(i);
        String? bgPath;
        try {
          final longest = math.max(pg.width, pg.height);
          // 目标 2x，但整体不超过 maxSide
          final scale = longest > 0 ? math.min(2.0, maxSide / longest) : 2.0;
          final img = await pg.render(
            // render() 的宽度/高度是 double，.round() 得到的 int 传不进去；
            // roundToDouble() 既取整又是 double，避免半像素导致的重采样模糊。
            width: (pg.width * scale).roundToDouble(),
            height: (pg.height * scale).roundToDouble(),
          );
          final bytes = img?.bytes;
          if (bytes != null) {
            bgPath = '${bgDir.path}/${const Uuid().v4()}_$i.png';
            await File(bgPath).writeAsBytes(bytes);
          }
        } catch (_) {
          // 单页渲染失败（加密页 / 损坏 / 内存不足）：退化成空白页，
          // 不能让整本导入失败。bgPath 保持 null，屏幕与导出都会按空白页处理。
          bgPath = null;
        }
        pages.add(Page(
          id: const Uuid().v4(),
          strokes: const [],
          bgPath: bgPath,
          width: pg.width,
          height: pg.height,
        ));
        await pg.close();
      }
    } finally {
      // 必须放在 finally：中途抛异常时若不关闭文档，原生侧句柄会一直泄漏。
      await doc.close();
    }
    return pages;
  }
}

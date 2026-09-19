import 'dart:io';

import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';

import '../models/content.dart';
import '../models/page.dart';
import '../models/stroke.dart';

/// Word（.docx）导入：把文档正文按段落提取成纯文本块。
///
/// 实现说明（离线、无网络、无外部服务）：
/// .docx 本质是一个 zip 包，正文在 `word/document.xml` 里。
/// 这里只取段落 `<w:p>` 内的文本节点 `<w:t>`，忽略图片、表格结构、字体等排版信息 ——
/// 目标是「把文字搬进笔记继续手写批注」，而不是复刻 Word 排版。
class DocxImport {
  /// 读取 .docx，按段落返回文本列表（空段落已剔除）。
  static Future<List<String>> paragraphs(String path) async {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive.files) {
      if (f.name != 'word/document.xml') continue;
      final content = f.content;
      if (content == null) continue;
      final xml = String.fromCharCodes(content);
      return _parse(xml);
    }
    throw const FormatException('不是有效的 .docx（缺少 word/document.xml）');
  }

  static List<String> _parse(String xml) {
    final out = <String>[];
    // 段落：非贪婪匹配 <w:p ...> ... </w:p>
    final paras =
        RegExp(r'<w:p\b[^>]*>(.*?)</w:p>', dotAll: true).allMatches(xml);
    for (final m in paras) {
      final body = m.group(1) ?? '';
      final buf = StringBuffer();
      // 段落内：文本节点 <w:t>，以及制表符 / 换行（<w:tab/>、<w:br/>）
      for (final t in RegExp(r'<w:t\b[^>]*>(.*?)</w:t>|<w:tab\b[^>]*/?>|<w:br\b[^>]*/?>',
              dotAll: true)
          .allMatches(body)) {
        final raw = t.group(0) ?? '';
        if (raw.startsWith('<w:tab')) {
          buf.write('    ');
        } else if (raw.startsWith('<w:br')) {
          buf.write('\n');
        } else {
          buf.write(_unescape(t.group(1) ?? ''));
        }
      }
      final text = buf.toString().trim();
      if (text.isEmpty) continue; // 丢弃空段落，避免导入后满屏空白行
      out.add(text);
    }
    return out;
  }

  /// XML 实体还原。Word 实际产出的文档里，弯引号 / 破折号几乎都写成数字实体，
  /// 只还原 5 个命名实体的话，导入后满屏是 &#8217; 这类原始编码。
  /// 注意 &amp; 必须放在最后，否则会把还原出来的 & 再转义一次。
  static String _unescape(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&#8217;', '\u2019')
      .replaceAll('&rsquo;', '\u2019')
      .replaceAll('&#8216;', '\u2018')
      .replaceAll('&lsquo;', '\u2018')
      .replaceAll('&#34;', '"')
      .replaceAll('&quot;', '"')
      .replaceAll('&#8220;', '\u201c')
      .replaceAll('&ldquo;', '\u201c')
      .replaceAll('&#8221;', '\u201d')
      .replaceAll('&rdquo;', '\u201d')
      .replaceAll('&#8212;', '\u2014')
      .replaceAll('&mdash;', '\u2014')
      .replaceAll('&#8211;', '\u2013')
      .replaceAll('&ndash;', '\u2013')
      .replaceAll('&#8230;', '\u2026')
      .replaceAll('&hellip;', '\u2026')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  // ── 排版常量（A4 竖版 @72dpi 逻辑像素）──
  static const double _pageW = 595.0;
  static const double _pageH = 842.0;
  static const double _marginX = 60.0;
  static const double _marginTop = 70.0;
  static const double _marginBottom = 60.0;
  static const double _lineH = 26.0;
  static const double _fontSize = 15.0;
  static const double _paraGap = 10.0; // 段间距，视觉上区分原 Word 段落

  /// 把段落列表排版成笔记页面（共享逻辑，编辑器导入 / 首页 Word 新建都用）。
  ///
  /// - 长段落按每行可容纳字符数折行（中文按全宽估算），
  ///   避免固定单行 TextBox 装不下导致文字溢出/看不全；
  /// - 按页面可用高度自动分页；
  /// - 段落之间留 _paraGap，保留原文档的段落结构感。
  static List<Page> buildPages(List<String> paras) {
    final boxW = _pageW - _marginX * 2;
    // 每行字符数：字号 15，全角字符宽≈fontSize，保守取 0.95 防止英文行过满
    final charsPerLine = (boxW / (_fontSize * 0.95)).floor();
    final maxBottom = _pageH - _marginBottom;

    final pages = <Page>[];
    var boxes = <TextBox>[];
    var y = _marginTop;

    void newPage() {
      pages.add(Page(
        id: const Uuid().v4(),
        strokes: const <Stroke>[],
        textBoxes: boxes,
        width: _pageW,
        height: _pageH,
      ));
      boxes = <TextBox>[];
      y = _marginTop;
    }

    for (final para in paras) {
      // 先按段落内的显式换行（Word 的 <w:br/> 软回车）拆开再折行。
      // 不拆的话带软回车的段落会被按字符数硬切，既丢了原本的换行位置，
      // 也会因为 TextBox 只有一行高而让后面的文字溢出看不见。
      final lines = <String>[];
      for (final seg in para.split('\n')) {
        lines.addAll(_wrap(seg, charsPerLine));
      }
      for (var li = 0; li < lines.length; li++) {
        if (y + _lineH > maxBottom) newPage();
        boxes.add(TextBox(
          id: const Uuid().v4(),
          x: _marginX,
          y: y,
          w: boxW,
          h: _lineH,
          text: lines[li],
          fontSize: _fontSize,
        ));
        y += _lineH;
      }
      // 段间距（不足一行就换页）
      if (y + _paraGap > maxBottom) {
        newPage();
      } else {
        y += _paraGap;
      }
    }
    // pages.isEmpty 也要建一页：空文档（或段落全为空、已在 _parse 里被剔除）
    // 若产出 0 页，Note.pages 就是空列表，编辑器取 pages[_page] 会直接越界。
    if (boxes.isNotEmpty || pages.isEmpty) newPage();
    return pages;
  }

  /// 按每行可容纳字符数折行，尽量从空格处断开。
  /// 纯按字符数硬切会把英文单词从中间劈开；中文没有空格，仍按字符切。
  static List<String> _wrap(String s, int per) {
    if (per <= 0) return [s];
    if (s.length <= per) return [s];
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      var end = i + per;
      if (end >= s.length) {
        out.add(s.substring(i));
        break;
      }
      // 在窗口内找最后一个空格，从词边界断开；找不到（或断点太靠前、
      // 会把这一行切得过短）就退化为硬切
      final cut = s.lastIndexOf(' ', end);
      if (cut > i + per ~/ 2) end = cut;
      out.add(s.substring(i, end).trimRight());
      i = end;
      while (i < s.length && s[i] == ' ') {
        i++;
      }
    }
    return out;
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/note.dart';

/// 一条搜索命中。
class OcrHit {
  final String noteId;
  final String noteTitle;
  final int pageIndex;
  final String snippet;
  final bool titleMatch;

  const OcrHit({
    required this.noteId,
    required this.noteTitle,
    required this.pageIndex,
    required this.snippet,
    this.titleMatch = false,
  });
}

/// 笔记全文索引（OCR 结果缓存）。
///
/// 落盘位置：`<documents>/ocr_index.json`
/// 结构：`{ "<noteId>": { "<pageIndex>": "识别出的文字" } }`
class OcrIndex {
  static Map<String, Map<String, String>>? _cache;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/ocr_index.json');
  }

  static Future<Map<String, Map<String, String>>> _data() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _cache = {
          for (final e in raw.entries)
            e.key: {
              for (final p in (e.value as Map<String, dynamic>).entries)
                p.key: p.value as String
            }
        };
        return _cache!;
      }
    } catch (_) {}
    _cache = {};
    return _cache!;
  }

  static Future<void> _flush() async {
    final f = await _file();
    // 原子写：写一半被中断会留下半截 JSON，_data() 的 catch 会把它当成
    // 「索引为空」静默吞掉 —— 用户建过的索引全部消失且毫无提示。
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(_cache ?? {}));
    try {
      await tmp.rename(f.path);
    } catch (_) {
      // Windows 的 rename 不允许覆盖已存在文件
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  }

  /// 写入/覆盖某页的识别文本（空文本视为删除该页索引）。
  static Future<void> putPage(String noteId, int pageIndex, String text) async {
    final d = await _data();
    final m = d.putIfAbsent(noteId, () => {});
    if (text.trim().isEmpty) {
      m.remove('$pageIndex');
      if (m.isEmpty) d.remove(noteId);
    } else {
      m['$pageIndex'] = text;
    }
    await _flush();
  }

  /// 某页是否已有索引。
  static Future<bool> hasPage(String noteId, int pageIndex) async {
    final d = await _data();
    return d[noteId]?.containsKey('$pageIndex') ?? false;
  }

  static Future<String?> pageText(String noteId, int pageIndex) async {
    final d = await _data();
    return d[noteId]?['$pageIndex'];
  }

  /// 笔记被删除时清理它的索引。
  static Future<void> removeNote(String noteId) async {
    final d = await _data();
    if (d.remove(noteId) != null) await _flush();
  }

  /// 已索引的页数总计。
  static Future<int> indexedPageCount() async {
    final d = await _data();
    return d.values.fold<int>(0, (a, m) => a + m.length);
  }

  static Future<void> clearAll() async {
    _cache = {};
    await _flush();
  }

  /// 搜索：同时匹配笔记标题与页内识别文字。
  static Future<List<OcrHit>> search(String query, List<Note> notes) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final lower = q.toLowerCase();
    final d = await _data();
    final titleById = {for (final n in notes) n.id: n.title};
    final hits = <OcrHit>[];

    // 标题命中
    for (final n in notes) {
      if (n.title.toLowerCase().contains(lower)) {
        hits.add(OcrHit(
          noteId: n.id,
          noteTitle: n.title,
          pageIndex: 0,
          snippet: '标题匹配',
          titleMatch: true,
        ));
      }
    }

    // 正文（OCR）命中
    for (final e in d.entries) {
      final title = titleById[e.key];
      if (title == null) continue; // 笔记已删除，跳过
      for (final p in e.value.entries) {
        final text = p.value;
        final idx = text.toLowerCase().indexOf(lower);
        if (idx < 0) continue;
        hits.add(OcrHit(
          noteId: e.key,
          noteTitle: title,
          pageIndex: int.tryParse(p.key) ?? 0,
          snippet: _snippet(text, idx, q.length),
        ));
      }
    }
    return hits;
  }

  static String _snippet(String text, int at, int len) {
    final flat = text.replaceAll('\n', ' ');
    final start = (at - 18).clamp(0, flat.length);
    final end = (at + len + 22).clamp(0, flat.length);
    final s = flat.substring(start, end).trim();
    return '${start > 0 ? '…' : ''}$s${end < flat.length ? '…' : ''}';
  }
}

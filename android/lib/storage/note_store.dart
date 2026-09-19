import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../models/page.dart';

/// 本地存储：每本笔记一个 <id>.json，全程本地、无网络。
class NoteStore {
  static const String _ext = '.json';

  Future<Directory> get _dir async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/notes');

  /// notes 目录里并不只有笔记：
  ///  - <noteId>_cards.json 是闪卡数据（旧版本布局，新版已挪到 notes/cards/ 子目录）；
  ///  - _meta.json 是备份包附带的标签/文件夹定义。
  /// 它们都不是 Note，`id` 字段缺失会让 Note.fromJson 直接抛异常 ——
  /// 若不排除，就会被当成「损坏的笔记」隔离改名，用户建的闪卡凭空消失。
  static bool _isForeign(String path) =>
      path.endsWith('_cards.json') || path.endsWith('_meta.json');

  /// 列出笔记。默认排除回收站（trashedAt != null）。
  /// [tagId] 非空时仅返回含该标签的笔记；[favoriteOnly] 为真时仅返回收藏。
  /// [folderId] 非空时仅返回该文件夹内的笔记；[unfiledOnly] 为真时仅返回未归档的。
  ///
  /// 文件夹这两个参数是分开的，不能合成一个可空的 folderId：
  /// 「未归档」是 folderId == null，而「不按文件夹筛选」也是 null，两者会撞车。
  Future<List<Note>> listNotes(
      {String? tagId,
      bool? favoriteOnly,
      String? folderId,
      bool unfiledOnly = false}) async {
    final dir = await _dir;
    if (!await dir.exists()) return [];
    final notes = <Note>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith(_ext) && !_isForeign(e.path)) {
        try {
          final j = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          final n = Note.fromJson(j);
          if (n.trashedAt != null) continue; // 回收站不显示在普通列表
          if (tagId != null && !n.tags.contains(tagId)) continue;
          if (favoriteOnly == true && !n.favorite) continue;
          if (folderId != null && n.folderId != folderId) continue;
          if (unfiledOnly && n.folderId != null) continue;
          notes.add(n);
        } catch (_) {
          // 解析失败 = 文件已损坏（多半是写入被中断留下的半截 JSON）。
          // 不能只是静默跳过：留一份 .corrupt 副本，数据还有手工恢复的可能，
          // 也比让它一直躺在目录里被误当成正常笔记要好。
          await _quarantine(e);
        }
      }
    }
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notes;
  }

  /// 回收站列表（按删除时间倒序）。
  Future<List<Note>> listTrash() async {
    final dir = await _dir;
    if (!await dir.exists()) return [];
    final notes = <Note>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith(_ext) && !_isForeign(e.path)) {
        try {
          final n = Note.fromJson(jsonDecode(await e.readAsString()) as Map<String, dynamic>);
          if (n.trashedAt != null) notes.add(n);
        } catch (_) {
          await _quarantine(e);
        }
      }
    }
    notes.sort((a, b) => (b.trashedAt ?? 0).compareTo(a.trashedAt ?? 0));
    return notes;
  }

  Future<Note> loadNote(String id) async {
    final f = File('${(await _dir).path}/$id$_ext');
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return Note.fromJson(j);
  }

  /// 把损坏的笔记文件改名隔离（保留内容，不再被当作正常笔记解析）。
  /// 二次确认它确实是笔记：notes 目录里可能混着别的 .json，
  /// 误改它们的名字等于毁掉那部分数据。
  static Future<void> _quarantine(File f) async {
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic> || !j.containsKey('pages')) return;
      await f.rename('${f.path}.corrupt_${DateTime.now().millisecondsSinceEpoch}');
    } catch (_) {}
  }

  Future<void> saveNote(Note note) async {
    final dir = await _dir;
    await dir.create(recursive: true);
    final f = File('${dir.path}/${note.id}$_ext');
    // 原子写：先落临时文件，再替换目标。
    // 直接 writeAsString 时，一旦写入途中进程被杀（切后台被系统回收 / 电量耗尽 /
    // 写到一半崩溃），JSON 会留在半截状态 —— 下次启动 Note.fromJson 解析失败，
    // listNotes 的 catch 又静默跳过它，用户看到的就是「笔记凭空消失了」。
    // 走临时文件后，最坏情况只是这次改动没生效，旧文件仍然完整可读。
    final tmp = File('${dir.path}/${note.id}$_ext.tmp');
    await tmp.writeAsString(jsonEncode(note.toJson()));
    try {
      await tmp.rename(f.path);
    } catch (_) {
      // Windows 的 rename 不允许覆盖已存在文件，退化成「删旧 → 改新」。
      // 窗口极小（两条语句之间），且此时数据已安全落盘。
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  }

  /// [folderId]：新建时直接放进指定文件夹（用户在某个文件夹里点「新建」时的预期行为），
  /// 留空则未归档，之后可用「移动到文件夹」归位。
  Future<Note> createBlank({String? folderId}) async {
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = Note(
      id: id,
      title: '未命名笔记',
      createdAt: now,
      updatedAt: now,
      pages: [Page(id: const Uuid().v4(), strokes: const [])],
      folderId: folderId,
    );
    await saveNote(note);
    return note;
  }

  /// 按向导参数新建：纸张尺寸 / 模板 / 配色 / 无边画布。
  Future<Note> createCustom({
    required String title,
    double width = 595.0,
    double height = 842.0,
    PageTemplate template = PageTemplate.none,
    int? paperColor,
    bool unbounded = false,
    String? folderId,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = Note(
      id: id,
      title: title.isEmpty ? '未命名笔记' : title,
      createdAt: now,
      updatedAt: now,
      pages: [
        Page(
          id: const Uuid().v4(),
          strokes: const [],
          width: width,
          height: height,
          template: template,
          paperColor: paperColor,
          unbounded: unbounded,
        )
      ],
      folderId: folderId,
    );
    await saveNote(note);
    return note;
  }

  Future<Note> createFromPages(List<Page> pages, String title) async {
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = Note(id: id, title: title, createdAt: now, updatedAt: now, pages: pages);
    await saveNote(note);
    return note;
  }

  /// 移入回收站（软删除）：置 trashedAt，文件保留，可被恢复。
  Future<void> trashNote(String id) async {
    final note = await loadNote(id);
    await saveNote(note.copyWith(trashedAt: DateTime.now().millisecondsSinceEpoch));
  }

  /// 从回收站恢复：清除 trashedAt。
  Future<void> restoreNote(String id) async {
    final note = await loadNote(id);
    await saveNote(note.copyWith(trashedAt: null));
  }

  /// 永久删除（回收站内或普通误调）：直接移除文件。
  Future<void> deleteNote(String id) async {
    final f = File('${(await _dir).path}/$id$_ext');
    if (await f.exists()) await f.delete();
  }

  /// 清空回收站：删除全部 trashed 笔记文件。
  Future<void> emptyTrash() async {
    final trash = await listTrash();
    for (final n in trash) {
      await deleteNote(n.id);
    }
  }
}

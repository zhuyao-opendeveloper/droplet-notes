import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/folders.dart';
import '../data/tags.dart';

/// 备份 / 恢复整个笔记库（notes 目录：所有 .json 笔记 + 引用的图片文件
/// + 标签/文件夹定义）。纯本地，无任何网络。
class Backup {
  /// 备份里附带的元数据文件名。
  ///
  /// 标签与文件夹的定义存在 SharedPreferences 里，**不在 notes 目录**。
  /// 只打包笔记文件的话，恢复后这些定义全部丢失：笔记上的 folderId 还在，
  /// 但对应的文件夹没了 —— 卡片不显示归属、筛选行里也找不到它，
  /// 用户看到的就是"恢复完一批笔记不见了"（其实都在「全部」里）。
  static const String metaFile = '_meta.json';
  static Future<Directory> get _notesDir async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/notes');

  /// 自动备份的最小间隔。写笔记时每提交一笔都会触发一次保存，
  /// 若每次都整库打包（含所有图片），几十笔就能生成几十个上百 MB 的 zip、
  /// 把磁盘吃满，同时每笔都要读一遍全库导致明显卡顿。
  static const Duration minInterval = Duration(minutes: 5);

  /// 自动备份最多保留的份数（超出按时间从旧到新删除）。
  static const int keepBackups = 5;

  static const String _prefix = 'hydronotes_backup_';
  static DateTime? _lastAuto;

  static String _ts() {
    final t = DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }

  /// 把整个 notes 目录打包为 zip，返回 zip 路径。
  static Future<String> backupAll() async {
    final dir = await _notesDir;
    final archive = Archive();
    if (await dir.exists()) {
      await for (final e in dir.list(recursive: true)) {
        if (e is File) {
          final rel =
              e.path.substring(dir.path.length + 1).replaceAll(r'\', '/');
          final data = await e.readAsBytes();
          archive.addFile(ArchiveFile(rel, data.length, data));
        }
      }
    }
    await _addMeta(archive);
    final enc = ZipEncoder().encode(archive);
    final out =
        File('${(await getApplicationDocumentsDirectory()).path}/$_prefix${_ts()}.zip');
    await out.writeAsBytes(enc!);
    return out.path;
  }

  /// 把标签 / 文件夹定义一并写进备份包。
  static Future<void> _addMeta(Archive archive) async {
    try {
      final p = await SharedPreferences.getInstance();
      final meta = jsonEncode({
        'tags': p.getString('tags') ?? '[]',
        'folders': p.getString('folders') ?? '[]',
      });
      final data = utf8.encode(meta);
      archive.addFile(ArchiveFile(metaFile, data.length, data));
    } catch (_) {
      // 元数据写不进去不影响笔记本体，不该让整次备份失败
    }
  }

  /// 自动备份入口（供编辑器每笔保存后调用）：节流 + 轮转。
  /// 距上次备份不足 [minInterval] 时直接跳过，返回 null。
  static Future<String?> backupThrottled() async {
    final now = DateTime.now();
    if (_lastAuto != null && now.difference(_lastAuto!) < minInterval) {
      return null;
    }
    final path = await backupAll();
    _lastAuto = now;
    await _rotate();
    return path;
  }

  /// 只保留最近 [keepBackups] 份自动备份。文件名含秒级时间戳，
  /// 字典序即时间序，倒序后跳过前 N 份，其余删除。
  static Future<void> _rotate() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      final files = <File>[];
      await for (final e in d.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith(_prefix) && name.endsWith('.zip')) files.add(e);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(keepBackups)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 从 zip 恢复整个 notes 目录（覆盖同名文件），并还原标签 / 文件夹定义。
  static Future<void> restoreAll(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final arch = ZipDecoder().decodeBytes(bytes);
    final dir = await _notesDir;
    await dir.create(recursive: true);
    for (final f in arch) {
      if (!f.isFile) continue;
      if (f.name == metaFile) continue; // 元数据不能落进 notes 目录（会被当成笔记文件扫描）
      final dest = File('${dir.path}/${f.name}');
      await dest.create(recursive: true);
      await dest.writeAsBytes(f.content as List<int>);
    }
    await _restoreMeta(arch);
  }

  /// 还原标签 / 文件夹定义，并让两处内存缓存失效，首页立刻能看到。
  /// 旧备份（没有 _meta.json）直接跳过，行为与以前一致。
  static Future<void> _restoreMeta(Archive arch) async {
    try {
      ArchiveFile? mf;
      for (final f in arch) {
        if (f.isFile && f.name == metaFile) mf = f;
      }
      if (mf == null) return;
      final j = jsonDecode(utf8.decode(mf.content as List<int>));
      if (j is! Map<String, dynamic>) return;
      final p = await SharedPreferences.getInstance();
      final tags = j['tags'];
      final folders = j['folders'];
      if (tags is String) await p.setString('tags', tags);
      if (folders is String) await p.setString('folders', folders);
      // 缓存不清，首页读到的还是恢复前的旧列表
      TagStore.invalidateCache();
      FolderStore.invalidateCache();
    } catch (_) {}
  }
}

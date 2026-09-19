import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'tags.dart';

/// 笔记文件夹：与标签同构 —— 定义集中存 SharedPreferences，Note 只持有 folderId。
///
/// `folderId == null` 表示「未归档」，这是一个正常状态而不是错误：
/// 老笔记根本没有这个字段，反序列化时缺失即视为未归档，
/// 用户升级后不会有任何一本笔记"找不到了"。
class Folder {
  final String id;
  final String name;
  final int color; // 0..7，对应 TagStore.palette 下标（与标签共用一套配色）

  const Folder({required this.id, required this.name, this.color = 4});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color};

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
        id: j['id'] as String,
        name: j['name'] as String? ?? '未命名文件夹',
        color: (j['color'] as int?)?.clamp(0, TagStore.palette.length - 1) ?? 4,
      );
}

class FolderStore {
  static List<Folder> _cache = const [];
  static bool _loaded = false;

  static Future<List<Folder>> list() async {
    if (_loaded) return _cache;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('folders');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List;
        _cache = decoded
            .map((e) => Folder.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _cache = const [];
      }
    }
    _loaded = true;
    return _cache;
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'folders', jsonEncode(_cache.map((f) => f.toJson()).toList()));
  }

  static Future<Folder> create(String name, [int color = 4]) async {
    final f = Folder(
      id: const Uuid().v4(),
      name: name,
      color: color.clamp(0, TagStore.palette.length - 1),
    );
    final cur = await list();
    _cache = [...cur, f];
    await _persist();
    return f;
  }

  static Future<void> rename(String id, String name) async {
    final cur = await list();
    _cache = cur
        .map((f) => f.id == id ? Folder(id: f.id, name: name, color: f.color) : f)
        .toList();
    await _persist();
  }

  static Future<void> setColor(String id, int color) async {
    final cur = await list();
    _cache = cur
        .map((f) => f.id == id
            ? Folder(
                id: f.id,
                name: f.name,
                color: color.clamp(0, TagStore.palette.length - 1))
            : f)
        .toList();
    await _persist();
  }

  static Future<void> remove(String id) async {
    final cur = await list();
    _cache = cur.where((f) => f.id != id).toList();
    await _persist();
  }

  static Folder? byId(String? id) {
    if (id == null) return null;
    for (final f in _cache) {
      if (f.id == id) return f;
    }
    return null;
  }

  static void invalidateCache() => _loaded = false;
}

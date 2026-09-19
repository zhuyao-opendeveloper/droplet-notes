import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 全局标签定义（Notein §5.4：8 种颜色，可新建/编辑/删除，按颜色筛选）。
/// 与笔记解耦：Note 仅持有 tagId 列表，标签本身集中存于 SharedPreferences。
class Tag {
  final String id;
  final String name;
  final int color; // 0..7，对应 TagStore.palette 下标

  const Tag({required this.id, required this.name, required this.color});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color};

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        color: (j['color'] as int?)?.clamp(0, TagStore.palette.length - 1) ?? 0,
      );
}

class TagStore {
  /// Notein 标签 8 色：红 / 橙 / 黄 / 绿 / 蓝 / 紫 / 灰 / 青
  static const List<int> palette = [
    0xFFE53935, // 红
    0xFFFF9800, // 橙
    0xFFFDD835, // 黄
    0xFF43A047, // 绿
    0xFF1E88E5, // 蓝
    0xFF8E24AA, // 紫
    0xFF9E9E9E, // 灰
    0xFF26A69A, // 青
  ];

  static const List<String> paletteNames = [
    '红',
    '橙',
    '黄',
    '绿',
    '蓝',
    '紫',
    '灰',
    '青',
  ];

  static List<Tag> _cache = const [];
  static bool _loaded = false;

  /// 列出全部标签（带内存缓存）。
  static Future<List<Tag>> list() async {
    if (_loaded) return _cache;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('tags');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List;
        _cache = decoded.map((e) => Tag.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        _cache = const [];
      }
    }
    _loaded = true;
    return _cache;
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('tags', jsonEncode(_cache.map((t) => t.toJson()).toList()));
  }

  /// 新建标签并返回。
  static Future<Tag> create(String name, int color) async {
    final t = Tag(id: const Uuid().v4(), name: name, color: color.clamp(0, palette.length - 1));
    final cur = await list();
    _cache = [...cur, t];
    await _persist();
    return t;
  }

  static Future<void> rename(String id, String name) async {
    final cur = await list();
    _cache = cur
        .map((t) => t.id == id ? Tag(id: t.id, name: name, color: t.color) : t)
        .toList();
    await _persist();
  }

  static Future<void> setColor(String id, int color) async {
    final cur = await list();
    _cache = cur
        .map((t) => t.id == id ? Tag(id: t.id, name: t.name, color: color.clamp(0, palette.length - 1)) : t)
        .toList();
    await _persist();
  }

  static Future<void> remove(String id) async {
    final cur = await list();
    _cache = cur.where((t) => t.id != id).toList();
    await _persist();
  }

  /// 按 id 取标签（用于把笔记的 tagId 解析成名称/颜色）。
  static Tag? byId(String id) {
    for (final t in _cache) {
      if (t.id == id) return t;
    }
    return null;
  }

  static void invalidateCache() => _loaded = false;
}

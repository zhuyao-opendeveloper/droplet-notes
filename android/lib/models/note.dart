import 'page.dart';

class Note {
  final String id;
  final String title;
  final int createdAt;
  final int updatedAt;
  final List<Page> pages;
  final String? audioPath; // 音频笔记录音文件（应用私有目录绝对路径）
  final int? audioStart; // 录音开始的基准时间戳（ms，DateTime.now().millisecondsSinceEpoch）
  final List<String> tags; // 标签 id 列表（Notein §5.4）
  final bool favorite; // 收藏 / 星标
  final int? trashedAt; // 回收站：移入时间戳；null = 正常
  final String? folderId; // 所属文件夹 id；null = 未归档

  const Note({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
    this.audioPath,
    this.audioStart,
    this.tags = const [],
    this.favorite = false,
    this.trashedAt,
    this.folderId,
  });

  Note copyWith({
    String? id,
    String? title,
    int? createdAt,
    int? updatedAt,
    List<Page>? pages,
    String? audioPath,
    int? audioStart,
    List<String>? tags,
    bool? favorite,
    int? trashedAt,
    String? folderId,
    /// 置 true 可把 folderId 清空为 null（移出文件夹）。
    /// 可选参数没法区分「没传」和「传了 null」——只写 `folderId ?? this.folderId`
    /// 的话，"移出文件夹"（想传 null）会永远失效。
    bool clearFolder = false,
  }) =>
      Note(
        id: id ?? this.id,
        title: title ?? this.title,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pages: pages ?? this.pages,
        audioPath: audioPath ?? this.audioPath,
        audioStart: audioStart ?? this.audioStart,
        tags: tags ?? this.tags,
        favorite: favorite ?? this.favorite,
        trashedAt: trashedAt ?? this.trashedAt,
        folderId: clearFolder ? null : (folderId ?? this.folderId),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'pages': pages.map((p) => p.toJson()).toList(),
        'tags': tags,
        'fav': favorite,
        if (trashedAt != null) 'trashedAt': trashedAt,
        if (audioPath != null) 'audio': audioPath,
        if (audioStart != null) 'audioStart': audioStart,
        if (folderId != null) 'folder': folderId,
      };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        title: j['title'] as String? ?? '未命名笔记',
        createdAt: j['createdAt'] as int? ?? 0,
        updatedAt: j['updatedAt'] as int? ?? 0,
        pages: (j['pages'] as List? ?? [])
            .map((e) => Page.fromJson(e as Map<String, dynamic>))
            .toList(),
        tags: ((j['tags'] as List?) ?? [])
            .map((e) => e as String)
            .toList(),
        favorite: j['fav'] as bool? ?? false,
        trashedAt: j['trashedAt'] as int?,
        audioPath: (j['audio'] as String?),
        audioStart: (j['audioStart'] as int?),
        // 老笔记没有这个字段 ⇒ 未归档，不是损坏数据
        folderId: j['folder'] as String?,
      );
}

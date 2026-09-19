/// 页面上的非笔迹内容项：文本框、图片。
/// 坐标均以「页面逻辑像素」(pageW×pageH) 为基准，缩放/旋转随画布统一处理。

class TextBox {
  final String id;
  final double x;
  final double y;
  final double w;
  final double h;
  final String text;
  final int color; // ARGB int
  final double fontSize;
  final int? bg; // 背景色（ARGB int，null=透明）
  final int? border; // 边框色（ARGB int，null=无边框）
  final double radius; // 圆角半径
  final bool bold; // 是否加粗
  final int align; // 0 左 / 1 中 / 2 右

  const TextBox({
    required this.id,
    required this.x,
    required this.y,
    this.w = 260,
    this.h = 120,
    this.text = '',
    this.color = 0xFF000000,
    this.fontSize = 18,
    this.bg,
    this.border,
    this.radius = 0,
    this.bold = false,
    this.align = 0,
  });

  TextBox copyWith({
    String? id,
    double? x,
    double? y,
    double? w,
    double? h,
    String? text,
    int? color,
    double? fontSize,
    int? bg,
    int? border,
    double? radius,
    bool? bold,
    int? align,
  }) =>
      TextBox(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        text: text ?? this.text,
        color: color ?? this.color,
        fontSize: fontSize ?? this.fontSize,
        bg: bg ?? this.bg,
        border: border ?? this.border,
        radius: radius ?? this.radius,
        bold: bold ?? this.bold,
        align: align ?? this.align,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'text': text,
        'color': color,
        'fs': fontSize,
        if (bg != null) 'bg': bg,
        if (border != null) 'bd': border,
        if (radius != 0) 'r': radius,
        if (bold) 'b': true,
        if (align != 0) 'al': align,
      };

  factory TextBox.fromJson(Map<String, dynamic> j) => TextBox(
        id: j['id'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num? ?? 260).toDouble(),
        h: (j['h'] as num? ?? 120).toDouble(),
        text: (j['text'] as String?) ?? '',
        color: (j['color'] as int? ?? 0xFF000000),
        fontSize: (j['fs'] as num? ?? 18).toDouble(),
        bg: (j['bg'] as int?),
        border: (j['bd'] as int?),
        radius: (j['r'] as num? ?? 0).toDouble(),
        bold: (j['b'] as bool? ?? false),
        align: (j['al'] as int? ?? 0),
      );
}

class NoteImage {
  final String id;
  final double x;
  final double y;
  final double w;
  final double h;
  final String path; // 应用私有目录下的绝对路径
  /// 裁剪源矩形（占原图比例 0..1）：sx,sy,sw,sh。null=不裁剪。
  final Map<String, double>? crop;

  const NoteImage({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.path,
    this.crop,
  });

  NoteImage copyWith({
    String? id,
    double? x,
    double? y,
    double? w,
    double? h,
    String? path,
    Map<String, double>? crop,
    /// 置 true 可把 crop 清空为 null。
    /// 可选参数无法区分「没传」和「传了 null」，`crop ?? this.crop` 会让
    /// 「重置裁剪」（想传 null 清掉裁剪）完全失效 —— 点重置后裁剪纹丝不动。
    bool clearCrop = false,
  }) =>
      NoteImage(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        path: path ?? this.path,
        crop: clearCrop ? null : (crop ?? this.crop),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'path': path,
        if (crop != null) 'crop': crop,
      };

  factory NoteImage.fromJson(Map<String, dynamic> j) => NoteImage(
        id: j['id'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        path: j['path'] as String,
        crop: (j['crop'] as Map?)?.map((k, v) => MapEntry(k, (v as num).toDouble())),
      );
}

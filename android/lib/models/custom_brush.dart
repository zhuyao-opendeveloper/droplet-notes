import 'tool.dart';

/// 可自定义的笔刷类型（基础行为，决定压感对比 / 笔尖 / 平头等默认表现）。
enum BrushType {
  pen,
  brush,
  highlighter,
  pencil,
  vector,
  rainbow;

  Tool toolOf() => switch (this) {
        BrushType.pen => Tool.pen,
        BrushType.brush => Tool.brush,
        BrushType.highlighter => Tool.highlighter,
        BrushType.pencil => Tool.pencil,
        BrushType.vector => Tool.vector,
        BrushType.rainbow => Tool.rainbow,
      };

  String get label => const {
        BrushType.pen: '钢笔',
        BrushType.brush: '毛笔',
        BrushType.highlighter: '荧光',
        BrushType.pencil: '铅笔',
        BrushType.vector: '矢量',
        BrushType.rainbow: '彩虹',
      }[this]!;
}

/// 类型默认压感→笔宽对比（与 Freehand._thinningFor 对齐，便于「编写画笔」时给出合理默认值）。
double _naturalThinning(BrushType t, double tip) {
  final base = t == BrushType.brush
      ? 0.78
      : (t == BrushType.highlighter || t == BrushType.vector)
          ? 0.0
          : (t == BrushType.pencil ? 0.55 : 0.65);
  return (base * (0.45 + tip * 0.9)).clamp(0.0, 1.0);
}

/// 用户自定义笔刷：数据驱动的参数化笔刷定义。
///
/// 既能通过编辑器可视化调节，也能以 JSON 形式「编写 / 导入 / 导出」。
/// 落笔时把解析后的渲染参数烘焙进 [Stroke.meta]['brush']，使单笔笔迹自包含、
/// 即便日后删除该笔刷也能保持原样。
class CustomBrush {
  final String id;
  String name;
  BrushType type;
  int color; // ARGB int
  double size; // 基础宽度(px)
  double opacity; // 0..1
  double thinning; // 压感→笔宽对比 0..1
  double tipSharpness; // 笔尖锐度 0..1（端点收尖 + 宽度对比）
  bool smoothing; // 曲线平滑开关
  double curveSmooth; // 拟合平滑强度 0..1
  bool flat; // 荧光平头（cap=false）
  // —— 压感配置 ——
  bool pressureOn;
  double pressureOffset; // 最快处保留笔压基线 0..1
  double pressureDamping; // 笔压 EMA 阻尼 0..1
  double pressureEstimation; // 无笔时速度→笔压增益 0..1
  double pressureSensitivity; // 灵敏度 0.3..2

  CustomBrush({
    required this.id,
    required this.name,
    required this.type,
    required this.color,
    required this.size,
    this.opacity = 1.0,
    double? thinning,
    this.tipSharpness = 0.5,
    this.smoothing = true,
    this.curveSmooth = 0.6,
    this.flat = false,
    this.pressureOn = true,
    this.pressureOffset = 0.28,
    this.pressureDamping = 0.55,
    this.pressureEstimation = 0.62,
    this.pressureSensitivity = 1.0,
  }) : thinning = thinning ?? _naturalThinning(type, tipSharpness);

  /// 由当前编辑器实时状态新建一支笔刷（用于「保存当前笔刷」）。
  factory CustomBrush.fromCurrent(
    String id,
    String name,
    BrushType type,
    int color,
    double size,
    double opacity,
    bool flat, {
    double tipSharpness = 0.5,
    bool smoothing = true,
    double curveSmooth = 0.6,
    bool pressureOn = true,
    double pressureOffset = 0.28,
    double pressureDamping = 0.55,
    double pressureEstimation = 0.62,
    double pressureSensitivity = 1.0,
  }) =>
      CustomBrush(
        id: id,
        name: name,
        type: type,
        color: color,
        size: size,
        opacity: opacity,
        tipSharpness: tipSharpness,
        smoothing: smoothing,
        curveSmooth: curveSmooth,
        flat: flat,
        pressureOn: pressureOn,
        pressureOffset: pressureOffset,
        pressureDamping: pressureDamping,
        pressureEstimation: pressureEstimation,
        pressureSensitivity: pressureSensitivity,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'color': color,
        'size': size,
        'opacity': opacity,
        'thinning': thinning,
        'tip': tipSharpness,
        'smooth': smoothing,
        'curve': curveSmooth,
        'flat': flat,
        'p': {
          'on': pressureOn,
          'off': pressureOffset,
          'damp': pressureDamping,
          'est': pressureEstimation,
          'sens': pressureSensitivity,
        },
      };

  factory CustomBrush.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as Map?) ?? {};
    final type = BrushType.values.firstWhere(
      (t) => t.name == (j['type'] as String? ?? 'pen'),
      orElse: () => BrushType.pen,
    );
    final tip = ((j['tip'] as num?)?.toDouble() ?? 0.5);
    return CustomBrush(
      id: j['id'] as String? ?? _newId(),
      name: (j['name'] as String?) ?? type.label,
      type: type,
      color: (j['color'] as int?) ?? 0xFF000000,
      size: (j['size'] as num?)?.toDouble() ?? 4.0,
      opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
      tipSharpness: tip,
      thinning: (j['thinning'] as num?)?.toDouble() ?? _naturalThinning(type, tip),
      smoothing: (j['smooth'] as bool?) ?? true,
      curveSmooth: (j['curve'] as num?)?.toDouble() ?? 0.6,
      flat: (j['flat'] as bool?) ?? false,
      pressureOn: (p['on'] as bool?) ?? true,
      pressureOffset: (p['off'] as num?)?.toDouble() ?? 0.28,
      pressureDamping: (p['damp'] as num?)?.toDouble() ?? 0.55,
      pressureEstimation: (p['est'] as num?)?.toDouble() ?? 0.62,
      pressureSensitivity: (p['sens'] as num?)?.toDouble() ?? 1.0,
    );
  }

  CustomBrush copyWith({
    String? name,
    BrushType? type,
    int? color,
    double? size,
    double? opacity,
    double? thinning,
    double? tipSharpness,
    bool? smoothing,
    double? curveSmooth,
    bool? flat,
    bool? pressureOn,
    double? pressureOffset,
    double? pressureDamping,
    double? pressureEstimation,
    double? pressureSensitivity,
  }) =>
      CustomBrush(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        color: color ?? this.color,
        size: size ?? this.size,
        opacity: opacity ?? this.opacity,
        thinning: thinning ?? this.thinning,
        tipSharpness: tipSharpness ?? this.tipSharpness,
        smoothing: smoothing ?? this.smoothing,
        curveSmooth: curveSmooth ?? this.curveSmooth,
        flat: flat ?? this.flat,
        pressureOn: pressureOn ?? this.pressureOn,
        pressureOffset: pressureOffset ?? this.pressureOffset,
        pressureDamping: pressureDamping ?? this.pressureDamping,
        pressureEstimation: pressureEstimation ?? this.pressureEstimation,
        pressureSensitivity: pressureSensitivity ?? this.pressureSensitivity,
      );

  /// 落笔时烘焙进 Stroke.meta['brush'] 的紧凑参数（自包含，删除笔刷也不影响旧笔迹）。
  Map<String, dynamic> bakedMeta() => {
        'type': type.name,
        'thin': thinning,
        'tip': tipSharpness,
        'smooth': smoothing,
        'curve': curveSmooth,
        'flat': flat,
        'p': {
          'on': pressureOn,
          'off': pressureOffset,
          'damp': pressureDamping,
          'est': pressureEstimation,
          'sens': pressureSensitivity,
        },
      };

  /// 兼容现有 FloatingPenBox 的 preset 结构（额外带 isCustom/id/name 供编辑器识别）。
  Map<String, dynamic> toPresetMap() => {
        'tool': type.toolOf().name,
        'color': color,
        'size': size,
        'op': opacity,
        'flat': flat,
        'isCustom': true,
        'id': id,
        'name': name,
      };

  /// 几支起始笔刷，首次启动播种，方便用户立刻体验「自定义画笔」。
  static List<CustomBrush> defaults() => [
        CustomBrush(
          id: 'seed_ink',
          name: '浓墨钢笔',
          type: BrushType.pen,
          color: 0xFF1A1A1A,
          size: 5.0,
          tipSharpness: 0.7,
          thinning: 0.72,
          pressureSensitivity: 1.15,
        ),
        CustomBrush(
          id: 'seed_water',
          name: '水彩毛笔',
          type: BrushType.brush,
          color: 0xFF2D6CDF,
          size: 12.0,
          tipSharpness: 0.35,
          thinning: 0.82,
          pressureSensitivity: 1.3,
          pressureEstimation: 0.7,
        ),
        CustomBrush(
          id: 'seed_neon',
          name: '霓虹荧光',
          type: BrushType.highlighter,
          color: 0xFFFFE14D,
          size: 22.0,
          opacity: 0.55,
          flat: true,
          tipSharpness: 0.0,
          thinning: 0.0,
        ),
      ];

  static String _newId() =>
      'cb_${DateTime.now().microsecondsSinceEpoch}_${(1000 + (DateTime.now().millisecondsSinceEpoch % 9000))}';
}

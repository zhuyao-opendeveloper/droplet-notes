/// 标准调色板数据。
///
/// 色彩源自 GoodNotes PSPDFKit colors-*.plist 提取的标准 RGB 值（通用色彩知识，
/// 非任何专有代码 / SDK），可自由用于任何项目。
///
/// - rainbow：6 色相 × 4 明度档（适合手写笔刷，同类颜色深浅可选）
/// - modern / vintage：单档 6 色（粉彩 / 复古柔和）
/// - blackwhite：黑白灰 6 级
class Palettes {
  /// 6 色相 × 4 明度档：blue / green / yellow / orange / red / purple，
  /// 每个数组从「最浅」到「最深」排列。
  static const Map<String, List<String>> rainbow = {
    'blue': ['#1F59FF', '#0E37C9', '#132668', '#030E35'],
    'green': ['#76C200', '#377900', '#224000', '#162800'],
    'yellow': ['#EACA00', '#C5AA00', '#A07900', '#775200'],
    'orange': ['#D76C00', '#B74300', '#8F3700', '#612800'],
    'red': ['#C63031', '#980000', '#520000', '#2D0006'],
    'purple': ['#7F13E7', '#440084', '#33075D', '#1D0933'],
  };

  static const List<String> modern = [
    '#7700D9',
    '#009BD8',
    '#00D9AB',
    '#00DA00',
    '#D1D600',
    '#E73633'
  ];

  /// 旧「复古」组：实际偏明亮的现代粉彩，用户觉得「太现代」。
  /// 保留色值但更名为「流光」，避免与真正的做旧色混淆。
  static const List<String> vintage = [
    '#FFCC66',
    '#CCFF66',
    '#66FFCC',
    '#66CCFF',
    '#CC66FF',
    '#FFE680'
  ];

  /// 真·复古：低饱和、做旧的宣纸/旧墨/铜锈/褪色印泥色调，
  /// 模拟受潮、氧化、晒褪后的陈旧感（比流光组明显更灰、更沉）。
  static const List<String> retro = [
    '#A8574F', // 褪色朱砂
    '#B07A78', // 玫瑰灰
    '#C79A3B', // 芥末 / 旧金
    '#8A5A44', // 砖褐
    '#6E7B4F', // 橄榄军绿
    '#4E7C6B', // 铜锈青
    '#46586B', // 旧靛蓝
    '#3B3A36', // 陈墨
  ];

  static const List<String> blackwhite = [
    '#FFFFFF',
    '#CCCCCC',
    '#999999',
    '#666666',
    '#333333',
    '#000000'
  ];

  /// rainbow 展开成扁平列表：按色相分组，每组内由浅到深。
  static List<String> get rainbowFlattened {
    final out = <String>[];
    for (final shades in rainbow.values) {
      out.addAll(shades);
    }
    return out;
  }

  /// 颜色选择对话框用的分组（标签页）。
  /// 「流光」= 原来的复古组（偏明亮的现代粉彩，用户反馈太现代，故更名保留）；
  /// 「复古」= 新排的低饱和做旧色。
  static final List<PaletteGroup> groups = [
    PaletteGroup('彩虹', rainbowFlattened),
    PaletteGroup('现代', modern),
    PaletteGroup('流光', vintage),
    PaletteGroup('复古', retro),
    PaletteGroup('黑白', blackwhite),
  ];
}

/// 一组颜色（hex 字符串）及其显示名。
class PaletteGroup {
  final String name;
  final List<String> colors;
  const PaletteGroup(this.name, this.colors);
}

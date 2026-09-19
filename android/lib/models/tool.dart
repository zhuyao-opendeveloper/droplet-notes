enum Tool {
  pen,
  brush,
  highlighter,
  pencil, // 铅笔：硬边石墨感，无锥度（批次18）
  rainbow, // 彩虹笔：沿笔迹色相循环（批次18）
  vector, // 矢量笔：等宽无压感锥度（批次18）
  smartPen, // 智能钢笔：z_math 变宽笔迹，粗细由书写速度驱动，不需压感硬件
  eraser,
  tape,
  line,
  rect,
  ellipse,
  triangle,
  arrow,
  lasso,
  text,
  laser;

  bool get isShape =>
      this == Tool.line ||
      this == Tool.rect ||
      this == Tool.ellipse ||
      this == Tool.triangle ||
      this == Tool.arrow;

  bool get isEraser => this == Tool.eraser;

  /// 胶带笔：半透明覆盖层，可叠在笔迹上做遮挡 / 标注，可视为可剥离贴层。
  bool get isTape => this == Tool.tape;

  bool get isLasso => this == Tool.lasso;

  bool get isText => this == Tool.text;

  /// 真正的书写笔（钢笔/毛笔/荧光笔/胶带笔/激光笔/铅笔/彩虹/矢量），走实时压感路径。
  bool get isPenLike =>
      this == Tool.pen ||
      this == Tool.brush ||
      this == Tool.highlighter ||
      this == Tool.tape ||
      this == Tool.laser ||
      this == Tool.pencil ||
      this == Tool.rainbow ||
      this == Tool.vector ||
      this == Tool.smartPen;

  bool get isLaser => this == Tool.laser;

  /// 形状识别结果对应的形状工具（供手绘图形识别落笔时使用）。
  static Tool fromShapeKind(String name) => switch (name) {
        'line' => Tool.line,
        'rect' => Tool.rect,
        'ellipse' => Tool.ellipse,
        'triangle' => Tool.triangle,
        'arrow' => Tool.arrow,
        _ => Tool.pen,
      };

  static Tool fromName(String name) =>
      Tool.values.firstWhere((t) => t.name == name, orElse: () => Tool.pen);
}

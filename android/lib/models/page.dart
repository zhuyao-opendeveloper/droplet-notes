import 'stroke.dart';
import 'layer.dart';
import 'content.dart';

enum PageTemplate {
  none,
  grid,
  line,
  dot,
  cornell,
  week,
  month,
  todos,
  checklist,
  math,
  music,
  column2,
  column3
}

class Page {
  final String id;
  final List<Stroke> strokes;
  final String? bgPath; // PDF 页渲染出的背景图路径；空=空白页
  final double width;
  final double height;
  /// 无边画布（无边笔记）：开启后允许写到页面可视边界之外，
  /// 编辑器会在笔画超出边界时自动扩展 width/height，页面随写随长。
  final bool unbounded;
  final PageTemplate template; // 空白页模板（网格/横线/点阵）
  final List<Layer> layers; // 图层（自下而上绘制）
  final double rotation; // 页面旋转（角度，0/90/180/270）
  final List<TextBox> textBoxes; // 文本框内容项
  final List<NoteImage> images; // 图片内容项
  final int? paperColor; // 纸张底色（ARGB int，null=白/护眼）

  const Page({
    required this.id,
    required this.strokes,
    this.bgPath,
    this.width = 595.0, // A4 @72dpi 逻辑像素
    this.height = 842.0,
    this.unbounded = false,
    this.template = PageTemplate.none,
    this.layers = const [Layer(id: Layer.defaultId, name: '内容')],
    this.rotation = 0.0,
    this.textBoxes = const [],
    this.images = const [],
    this.paperColor,
  });

  Page copyWith({
    String? id,
    List<Stroke>? strokes,
    String? bgPath,
    double? width,
    double? height,
    bool? unbounded,
    PageTemplate? template,
    List<Layer>? layers,
    double? rotation,
    List<TextBox>? textBoxes,
    List<NoteImage>? images,
    int? paperColor,
  }) =>
      Page(
        id: id ?? this.id,
        strokes: strokes ?? this.strokes,
        bgPath: bgPath ?? this.bgPath,
        width: width ?? this.width,
        height: height ?? this.height,
        unbounded: unbounded ?? this.unbounded,
        template: template ?? this.template,
        layers: layers ?? this.layers,
        rotation: rotation ?? this.rotation,
        textBoxes: textBoxes ?? this.textBoxes,
        images: images ?? this.images,
        paperColor: paperColor ?? this.paperColor,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'bgPath': bgPath,
        'w': width,
        'h': height,
        if (unbounded) 'unb': true,
        'tpl': template.index,
        'rot': rotation,
        if (paperColor != null) 'paper': paperColor,
        'layers': layers.map((l) => l.toJson()).toList(),
        'textBoxes': textBoxes.map((e) => e.toJson()).toList(),
        'images': images.map((e) => e.toJson()).toList(),
        'strokes': strokes.map((s) => s.toJson()).toList(),
      };

  factory Page.fromJson(Map<String, dynamic> j) => Page(
        id: j['id'] as String,
        bgPath: j['bgPath'] as String?,
        width: (j['w'] as num? ?? 595.0).toDouble(),
        height: (j['h'] as num? ?? 842.0).toDouble(),
        unbounded: (j['unb'] as bool? ?? false),
        template:
            PageTemplate.values[(j['tpl'] as int? ?? 0).clamp(0, PageTemplate.values.length - 1)],
        layers: ((j['layers'] as List?) ?? [])
            .map((e) => Layer.fromJson(e as Map<String, dynamic>))
            .toList(),
        rotation: (j['rot'] as num? ?? 0).toDouble(),
        textBoxes: ((j['textBoxes'] as List?) ?? [])
            .map((e) => TextBox.fromJson(e as Map<String, dynamic>))
            .toList(),
        images: ((j['images'] as List?) ?? [])
            .map((e) => NoteImage.fromJson(e as Map<String, dynamic>))
            .toList(),
        paperColor: (j['paper'] as int?),
        strokes: (j['strokes'] as List? ?? [])
            .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

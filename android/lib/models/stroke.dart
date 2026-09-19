import 'point.dart';
import 'tool.dart';

class Stroke {
  final String id;
  final Tool tool;
  final int color; // ARGB int
  final double size;
  final List<Point> points;
  final String layerId; // 所属图层（'content' 默认内容层）
  final double opacity; // 0..1 透明度（乘在 color 的 alpha 上）
  final int? t; // 音频回放时间戳（相对录音起点的毫秒偏移），null=非录音期笔迹
  final Map<String, dynamic>? meta; // 扩展：曲线控制点(curves)/箭头头(heads)/平移(translation) 等

  const Stroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
    this.layerId = 'content',
    this.opacity = 1.0,
    this.t,
    this.meta,
  });

  bool get isShape => tool.isShape;

  Map<String, dynamic> toJson() => {
        'id': id,
        'tool': tool.name,
        'color': color,
        'size': size,
        'points': points.map((p) => p.toJson()).toList(),
        'layer': layerId,
        'op': opacity,
        if (t != null) 't': t,
        if (meta != null) 'meta': meta,
      };

  factory Stroke.fromJson(Map<String, dynamic> j) => Stroke(
        id: j['id'] as String,
        tool: Tool.fromName(j['tool'] as String),
        color: j['color'] as int,
        size: (j['size'] as num).toDouble(),
        points: (j['points'] as List)
            .map((e) => Point.fromJson(e as Map<String, dynamic>))
            .toList(),
        layerId: (j['layer'] as String?) ?? 'content',
        opacity: (j['op'] as num?)?.toDouble() ?? 1.0,
        t: (j['t'] as int?),
        meta: (j['meta'] as Map<String, dynamic>?) ,
      );
}

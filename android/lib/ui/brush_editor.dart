import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/freehand.dart';
import '../models/custom_brush.dart';
import '../models/point.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../theme.dart';
import '../data/palettes.dart';
import '../widgets/anim.dart';

/// 画笔编辑器底部弹窗。
///
/// 支持两种「编写画笔」方式：
///  1. 可视化：类型 / 颜色 / 粗细 / 透明 / 压感对比 / 笔尖 / 平滑 等滑块，实时笔迹预览；
///  2. JSON：直接查看、编辑、复制、应用画笔定义（满足「编写画笔」）。
///
/// 保存即写入 [AppSettings.customBrushes] 并落盘；[onApplied] 回调让编辑器在保存后
/// 把该笔设为本页当前笔。
class BrushEditorSheet extends StatefulWidget {
  final CustomBrush brush;
  final void Function(CustomBrush brush)? onApplied;
  const BrushEditorSheet({super.key, required this.brush, this.onApplied});

  @override
  State<BrushEditorSheet> createState() => _BrushEditorSheetState();
}

class _BrushEditorSheetState extends State<BrushEditorSheet> {
  late CustomBrush _b;
  final TextEditingController _nameCtl = TextEditingController();
  final TextEditingController _jsonCtl = TextEditingController();
  bool _jsonError = false;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _b = widget.brush;
    _nameCtl.text = _b.name;
    _jsonCtl.text = _pretty(_b.toJson());
  }

  static String _pretty(Map<String, dynamic> j) =>
      const JsonEncoder.withIndent('  ').convert(j);

  @override
  void dispose() {
    _nameCtl.dispose();
    _jsonCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _mutate(CustomBrush Function(CustomBrush) fn) {
    setState(() {
      _b = fn(_b);
      _nameCtl.text = _b.name;
      _jsonCtl.text = _pretty(_b.toJson());
    });
  }

  void _applyJson() {
    try {
      final j = jsonDecode(_jsonCtl.text) as Map<String, dynamic>;
      final parsed = CustomBrush.fromJson(j);
      setState(() {
        _b = parsed;
        _nameCtl.text = _b.name;
        _jsonError = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已应用 JSON 画笔定义')));
    } catch (e) {
      setState(() => _jsonError = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('JSON 解析失败：$e')));
    }
  }

  void _save() {
    AppSettings.instance.upsertCustomBrush(_b);
    widget.onApplied?.call(_b);
    Navigator.pop(context);
  }

  void _delete() {
    AppSettings.instance.removeCustomBrush(_b.id);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.86),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // 顶部标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Icon(Icons.brush, color: cs.primary),
                const SizedBox(width: 8),
                Text('画笔编辑器',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface)),
                const Spacer(),
                TextButton(onPressed: _save, child: const Text('保存')),
                IconButton(onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ],
            ),
          ),
          // 实时预览
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            height: 84,
            decoration: BoxDecoration(
              color: cs.surfaceVariant.withOpacity(0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CustomPaint(
                painter: _BrushPreview(_b),
                size: const Size(double.infinity, 84),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                TextField(
                  controller: _nameCtl,
                  decoration: const InputDecoration(labelText: '画笔名称'),
                  onChanged: (v) => _mutate((b) => b.copyWith(name: v)),
                ),
                const SizedBox(height: 10),
                _typeRow(),
                const SizedBox(height: 10),
                _colorRow(cs),
                _slider('粗细', _b.size, 1, 60, (v) => _mutate((b) => b.copyWith(size: v))),
                _slider('透明', _b.opacity, 0.1, 1, (v) => _mutate((b) => b.copyWith(opacity: v))),
                _slider('笔尖锐度', _b.tipSharpness, 0, 1,
                    (v) => _mutate((b) => b.copyWith(tipSharpness: v))),
                _slider('压感对比', _b.thinning, 0, 1,
                    (v) => _mutate((b) => b.copyWith(thinning: v))),
                _switch('曲线平滑', _b.smoothing,
                    (v) => _mutate((b) => b.copyWith(smoothing: v))),
                if (_b.smoothing)
                  _slider('平滑强度', _b.curveSmooth, 0, 1,
                      (v) => _mutate((b) => b.copyWith(curveSmooth: v))),
                if (_b.type == BrushType.highlighter)
                  _switch('平头（荧光）', _b.flat,
                      (v) => _mutate((b) => b.copyWith(flat: v))),
                const Divider(height: 18),
                Text('压感', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
                _switch('启用压感', _b.pressureOn,
                    (v) => _mutate((b) => b.copyWith(pressureOn: v))),
                if (_b.pressureOn) ...[
                  _slider('笔压基线', _b.pressureOffset, 0, 1,
                      (v) => _mutate((b) => b.copyWith(pressureOffset: v))),
                  _slider('笔压阻尼', _b.pressureDamping, 0, 1,
                      (v) => _mutate((b) => b.copyWith(pressureDamping: v))),
                  _slider('速度估算', _b.pressureEstimation, 0, 1,
                      (v) => _mutate((b) => b.copyWith(pressureEstimation: v))),
                  _slider('灵敏度', _b.pressureSensitivity, 0.3, 2,
                      (v) => _mutate((b) => b.copyWith(pressureSensitivity: v))),
                ],
                const Divider(height: 18),
                Text('编写（JSON）',
                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _jsonCtl,
                  maxLines: 10,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    filled: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    hintText: '在此编写画笔 JSON，点「应用 JSON」生效',
                  ),
                ),
                if (_jsonError)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('JSON 有误，请检查',
                        style: TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _applyJson,
                        child: const Text('应用 JSON'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: _jsonCtl.text));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制 JSON')));
                          }
                        },
                        child: const Text('复制 JSON'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text('删除此画笔',
                      style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeRow() => DropdownButtonFormField<BrushType>(
        value: _b.type,
        decoration: const InputDecoration(labelText: '笔刷类型'),
        items: BrushType.values
            .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
            .toList(),
        onChanged: (t) {
          if (t == null) return;
          _mutate((b) => b.copyWith(type: t));
        },
      );

  Widget _colorRow(ColorScheme cs) {
    final swatches = Palettes.groups.expand((g) => g.colors).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: swatches.map((hex) {
        final c = _parse(hex);
        final active = c.value == _b.color;
        return PressScale(
          scale: 0.9,
          onTap: () => _mutate((b) => b.copyWith(color: c.value)),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? cs.primary : cs.outlineVariant,
                width: active ? 3 : 1,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _slider(String label, double v, double min, double max,
      void Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        Slider(
          value: v,
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _switch(String label, bool v, void Function(bool) onChanged) => SwitchListTile(
        title: Text(label),
        value: v,
        contentPadding: EdgeInsets.zero,
        onChanged: onChanged,
      );

  static Color _parse(String hex) {
    final h = hex.replaceFirst('#', '');
    return Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
  }
}

/// 笔迹预览绘制器。
class _BrushPreview extends CustomPainter {
  final CustomBrush brush;
  _BrushPreview(this.brush);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = <Point>[];
    for (int i = 0; i <= 80; i++) {
      final t = i / 80;
      final x = 16 + t * (size.width - 32);
      final y = size.height / 2 +
          math.sin(t * math.pi * 3) * (size.height * 0.24) * (0.4 + 0.6 * t);
      final pr = (0.4 + 0.5 * (0.5 + 0.5 * math.sin(t * math.pi * 4)))
          .clamp(0.05, 1.0);
      pts.add(Point(x, y, pr));
    }
    final stroke = Stroke(
      id: 'pv',
      tool: brush.type.toolOf(),
      color: brush.color,
      size: brush.size,
      points: pts,
      opacity: brush.opacity,
      meta: brush.bakedMeta(),
    );

    if (brush.type == BrushType.rainbow) {
      final cl = Freehand.centerline(stroke);
      if (cl.length >= 2) {
        for (var i = 1; i < cl.length; i++) {
          final hue = (i / cl.length) * 360;
          canvas.drawLine(
            cl[i - 1],
            cl[i],
            Paint()
              ..color = HSVColor.fromAHSV(brush.opacity, hue, 0.85, 1).toColor()
              ..strokeWidth = brush.size.clamp(1, 40)
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..style = PaintingStyle.stroke,
          );
        }
      }
      return;
    }

    final path = Freehand.buildPath(stroke);
    canvas.drawPath(
      path,
      Paint()
        ..color = Color(brush.color).withOpacity(brush.opacity)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _BrushPreview old) => old.brush != brush;
}

/// 便捷入口：从底部弹出画笔编辑器。
Future<void> showBrushEditor(BuildContext context, CustomBrush brush,
    {void Function(CustomBrush)? onApplied}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BrushEditorSheet(brush: brush, onApplied: onApplied),
  );
}

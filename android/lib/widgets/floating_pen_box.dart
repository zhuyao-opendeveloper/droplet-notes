import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anim.dart';

/// 悬浮笔盒（Floating Pen Box）
///
/// 一个浮在画布之上、可自由拖动的小面板：
/// - 折叠态是一枚 56dp 圆形按钮，展开态是 224×300 的预设面板；
/// - 拖动松手后自动吸附到左右最近的边缘（吸附过程有动画）；
/// - 位置与展开状态持久化到 SharedPreferences（penbox_x / penbox_y / penbox_open）；
/// - 展开 / 收起、内容切换、预设项按下均带动画（统一走 AppAnim）。
///
/// 用法：放在覆盖画布的 Stack 里占满一层即可，空白区域不拦截画布的手写事件。
class FloatingPenBox extends StatefulWidget {
  const FloatingPenBox({
    super.key,
    required this.presets,
    required this.current,
    required this.onApply,
    required this.onSave,
    required this.onDelete,
    this.onEdit,
  });

  /// 笔盒中的笔刷预设（每项含 tool / color / size / op）
  final List<Map<String, dynamic>> presets;

  /// 当前生效的笔刷，用于高亮命中的预设
  final Map<String, dynamic> current;

  final void Function(Map<String, dynamic> preset) onApply;
  final VoidCallback onSave;
  final void Function(Map<String, dynamic> preset) onDelete;
  /// 长按「自定义画笔」预设时打开编辑器（内置预设仍走删除）。
  final void Function(Map<String, dynamic> preset)? onEdit;

  @override
  State<FloatingPenBox> createState() => FloatingPenBoxState();
}

class FloatingPenBoxState extends State<FloatingPenBox> {
  static const double _collapsedSize = 56;
  static const double _panelW = 224;
  static const double _panelH = 300;
  static const double _margin = 12;

  bool _expanded = false;
  bool _dragging = false;
  bool _placed = false; // 是否已经根据父容器尺寸完成首次定位
  Offset _pos = Offset.zero;

  bool get _isPanel => _expanded;

  double get _w => _isPanel ? _panelW : _collapsedSize;
  double get _h => _isPanel ? _panelH : _collapsedSize;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _expanded = p.getBool('penbox_open') ?? false;
      final x = p.getDouble('penbox_x');
      final y = p.getDouble('penbox_y');
      if (x != null && y != null) {
        _pos = Offset(x, y);
        _placed = true; // 已存过位置，等拿到父尺寸后再 clamp
      }
    });
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('penbox_x', _pos.dx);
    await p.setDouble('penbox_y', _pos.dy);
    await p.setBool('penbox_open', _expanded);
  }

  void _onPanUpdate(Size box, Offset delta) {
    setState(() {
      _dragging = true;
      _pos = Offset(
        (_pos.dx + delta.dx).clamp(0.0, (box.width - _w).clamp(0.0, box.width)),
        (_pos.dy + delta.dy).clamp(0.0, (box.height - _h).clamp(0.0, box.height)),
      );
    });
  }

  /// 松手后吸附到左右最近边缘（水平方向），并落盘。
  void _onPanEnd(Size box) {
    final targetX = (_pos.dx + _w / 2) < box.width / 2
        ? _margin
        : (box.width - _w - _margin).clamp(0.0, box.width);
    setState(() {
      _dragging = false;
      _pos = Offset(
        targetX,
        _pos.dy.clamp(0.0, (box.height - _h).clamp(0.0, box.height)),
      );
    });
    _persist();
  }

  /// 展开笔盒（外部调用：工具栏按钮）
  void open() {
    if (_expanded) return;
    setState(() => _expanded = true);
    _persist();
  }

  /// 展开 / 收起切换
  void toggle() {
    setState(() => _expanded = !_expanded);
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (ctx, c) {
          final box = c.biggest;
          if (!_placed) {
            // 首次进入：默认停靠右下角（留出边距）
            _pos = Offset(
              (box.width - _w - _margin).clamp(0.0, box.width),
              (box.height - _h - _margin).clamp(0.0, box.height),
            );
            _placed = true;
          }
          // 尺寸变化（旋转 / 展开收起）后保证仍在可视区内
          final left = _pos.dx.clamp(0.0, (box.width - _w).clamp(0.0, box.width));
          final top = _pos.dy.clamp(0.0, (box.height - _h).clamp(0.0, box.height));
          if (left != _pos.dx || top != _pos.dy) {
            _pos = Offset(left, top);
          }
          return Stack(
            children: [
              AnimatedPositioned(
                duration: _dragging ? Duration.zero : AppAnim.normal,
                curve: AppAnim.curve,
                left: left,
                top: top,
                width: _w,
                height: _h,
                child: GestureDetector(
                  onPanUpdate: (d) => _onPanUpdate(box, d.delta),
                  onPanEnd: (_) => _onPanEnd(box),
                  // 只让折叠态点击展开；展开后点空白处不误收起
                  // （收起走右上角关闭按钮）
                  onTap: _isPanel ? null : toggle,
                  child: _body(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _body() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(_isPanel ? 18 : 28),
      clipBehavior: Clip.antiAlias,
      child: AnimatedContainer(
        duration: AppAnim.normal,
        curve: AppAnim.curve,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(_isPanel ? 18 : 28),
        ),
        child: AnimatedSwitcher(
          duration: AppAnim.fast,
          switchInCurve: AppAnim.curve,
          switchOutCurve: AppAnim.curveIn,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1.0).animate(a),
              child: child,
            ),
          ),
          child: _isPanel
              ? SizedBox(key: const ValueKey('penbox-panel'), child: _panel())
              : SizedBox(
                  key: const ValueKey('penbox-collapsed'),
                  width: _collapsedSize,
                  height: _collapsedSize,
                  child: Center(
                    child: Icon(
                      Icons.brush,
                      color: widget.presets.isEmpty
                          ? cs.onSurfaceVariant
                          : cs.primary,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _panel() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 顶部：拖动把手 + 保存 / 收起
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            color: cs.primary.withOpacity(0.08),
            child: Row(
              children: [
                const SizedBox(
                  width: 26,
                  child: Icon(Icons.drag_indicator, size: 18),
                ),
                Text('笔盒',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: cs.primary)),
                const Spacer(),
                PressScale(
                  tooltip: '保存当前笔刷',
                  onTap: widget.onSave,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.add, size: 18, color: cs.primary),
                  ),
                ),
                PressScale(
                  tooltip: '收起笔盒',
                  onTap: toggle,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.close, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: widget.presets.isEmpty
              ? Center(
                  child: Text(
                    '笔盒空\n点上方 + 保存当前笔刷',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: widget.presets.length,
                  itemBuilder: (_, i) {
                    final p = widget.presets[i];
                    final active = same(p, widget.current);
                    return FadeSlideIn(
                      delay: AppAnim.stagger * (i % 8),
                      duration: AppAnim.fast,
                      offset: const Offset(0, 0.18),
                      child: PressScale(
                        scale: 0.86,
                        onTap: () => widget.onApply(p),
                        onLongPress: p['isCustom'] == true
                            ? () => widget.onEdit?.call(p)
                            : () => _confirmDelete(p),
                        tooltip: p['isCustom'] == true
                            ? '${p['name'] as String} · '
                                '${(p['size'] as num).toDouble().round()} · 长按编辑'
                            : '${_toolLabel(p['tool'] as String)} · '
                                '${(p['size'] as num).toDouble().round()} · 长按删除',
                        child: AnimatedContainer(
                          duration: AppAnim.fast,
                          curve: AppAnim.curve,
                          decoration: BoxDecoration(
                            color: active
                                ? cs.primaryContainer
                                : cs.surfaceVariant.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: active ? cs.primary : cs.outlineVariant,
                              width: active ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: Color(p['color'] as int)
                                      .withOpacity((p['op'] as num).toDouble()),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: cs.outlineVariant),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _toolLabel(p['tool'] as String),
                                style: TextStyle(
                                    fontSize: 9,
                                    color: active ? cs.primary : null),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.presets.length} 个预设 · 长按删除',
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除预设'),
        content: Text(
            '删除「${_toolLabel(p['tool'] as String)} · '
            '${(p['size'] as num).toDouble().round()}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) widget.onDelete(p);
  }

  static bool same(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a['tool'] != b['tool']) return false;
    if (a['color'] != b['color']) return false;
    final sa = (a['size'] as num).toDouble();
    final sb = (b['size'] as num).toDouble();
    if ((sa - sb).abs() > 0.01) return false;
    final oa = (a['op'] as num).toDouble();
    final ob = (b['op'] as num).toDouble();
    return (oa - ob).abs() <= 0.01;
  }

  static String _toolLabel(String name) =>       const {
        'pen': '钢笔',
        'brush': '毛笔',
        'highlighter': '荧光',
        'pencil': '铅笔',
        'rainbow': '彩虹',
        'vector': '矢量',
        'eraser': '橡皮',
        'tape': '胶带',
        'laser': '激光',
        'line': '直线',
        'rect': '矩形',
        'ellipse': '椭圆',
        'arrow': '箭头',
        'lasso': '套索',
        'text': '文本',
      }[name] ??
      name;
}

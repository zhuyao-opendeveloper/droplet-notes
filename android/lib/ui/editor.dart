import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:uuid/uuid.dart';
import 'package:record/record.dart';

import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';

import '../models/note.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../models/page.dart';
import '../models/layer.dart';
import '../models/content.dart';
import '../models/custom_brush.dart';
import '../storage/note_store.dart';
import '../pdf/export.dart';
import '../import/docx_import.dart';
import '../engine/geometry.dart';
import 'package:printing/printing.dart';
import '../storage/backup.dart';
import '../theme.dart';
import '../widgets/handwriting_canvas.dart';
import '../widgets/anim.dart';
import '../widgets/floating_pen_box.dart';
import '../widgets/palette_dialog.dart';
import '../ui/brush_editor.dart';
import '../ui/playback.dart';
import '../ui/flashcard.dart';
import '../ui/ocr_page.dart';
import '../ocr/ocr_service.dart';
import '../ocr/ocr_index.dart';

class EditorPage extends StatefulWidget {
  final String noteId;
  final int initialPage; // 从搜索结果跳转时直接定位到某页
  const EditorPage(this.noteId, {super.key, this.initialPage = 0});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

/// 撤销/重做栈的条目：笔画 + 它在 strokes 列表中的原始下标。
/// 记录下标是为了重做时能插回原来的叠放位置，而不是被追加到最上层。
class _Hist {
  final Stroke stroke;
  final int index;
  const _Hist(this.stroke, this.index);
}

class _EditorPageState extends State<EditorPage>
    with SingleTickerProviderStateMixin {
  final NoteStore _store = NoteStore();
  final Record _recorder = Record();
  Note? _note;
  int _page = 0;
  Tool _tool = Tool.pen;
  Color _color = Colors.black;
  double _size = 4.0;
  double _opacity = 1.0;
  String _currentLayerId = Layer.defaultId;
  List<Map<String, dynamic>> _presets = [];
  int _readingMode = 0; // 0 单页 / 1 连续滚动 / 2 双页
  double _zoom = 1.0;
  // 撤销栈存的不是裸 Stroke，而是「笔画 + 它当时在 strokes 里的下标」。
  // 只存Stroke的话，重做只能 append 到末尾 —— 底层笔画撤销再重做后会盖到最上层，
  // 图层顺序被破坏。存下标才能插回原位。
  final List<_Hist> _undo = [];
  final List<_Hist> _redo = [];
  int _eraserMode = 0; // 0 整笔 / 1 区域(像素) / 2 只擦荧光笔
  bool _panMode = false; // 拖动模式（单指平移页面）；false=书写模式
  bool _rectLasso = false; // 套索用矩形框选；false=自由圈选
  /// 画布视口变换（双指缩放 / 拖动平移），供缩放按钮与 InteractiveViewer 共用。
  final TransformationController _viewer = TransformationController();
  bool _highlighterFlat = false; // 荧光笔平头（批次18）

  // —— 自定义画笔 ——
  // 当前生效的自定义画笔（null=使用内置工具 + 全局压感配置）。
  CustomBrush? _activeBrush;
  // 落笔时烘焙进 Stroke.meta 的紧凑参数（自包含，删除笔刷也不影响旧笔迹）。
  Map<String, dynamic>? _activeBrushMeta;
  bool _recording = false;
  int? _recBase; // 录音基准（微秒）
  NoteImage? _cropPendingImage; // 自由裁剪待处理图片
  // 文本样式默认
  int _tbColor = 0xFF000000;
  double _tbSize = 18;
  int? _tbBg;
  int? _tbBorder;
  double _tbRadius = 8;
  bool _tbBold = false;
  int _tbAlign = 0;
  // ---------- 动画 ----------
  /// 翻页淡入：值保持 1，切换页面时 forward(from: 0) 重播一次
  late final AnimationController _flipCtrl =
      AnimationController(vsync: this, duration: AppAnim.normal)..value = 1.0;
  double _undoTurns = 0; // 撤销按钮每点一次转一圈
  double _redoTurns = 0;
  final GlobalKey<FloatingPenBoxState> _penBoxKey =
      GlobalKey<FloatingPenBoxState>();

  /// 统一翻页入口：所有改页码的地方都走这里，才能统一播放翻页动画
  void _setPage(int p) {
    final max = (_note?.pages.length ?? 1) - 1;
    final np = p.clamp(0, max < 0 ? 0 : max);
    if (np == _page) return;
    // 撤销/重做栈是「当前页」的：切页必须清空，否则会把上一页的笔画重做到这一页。
    _undo.clear();
    _redo.clear();
    setState(() => _page = np);
    _flipCtrl.forward(from: 0);
  }

  /// 打开 / 收起悬浮笔盒（工具栏与属性栏的笔盒入口共用）
  void _openPenBox() {
    final st = _penBoxKey.currentState;
    if (st == null) return;
    st.toggle();
  }

  @override
  void initState() {
    super.initState();
    if (AppSettings.instance.immersive) {
      // setEnabledSystemUIOverlays 已在 Flutter 3.x 移除，改用 SystemUiMode
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _load();
    _loadPresets();
  }

  /// 结束录音收尾（供 dispose / 生命周期切换调用）。
  ///
  /// Record 插件的 dispose() 只释放插件侧资源，**不会自动停止录音**：
  /// 正在录音时直接退出编辑器，麦克风会被这个 App 一直占着（系统状态栏
  /// 持续显示录音中，别的 App 录不了音），而这段录音因为没有走 stop()
  /// 也根本没写进文件 —— 用户录了半天的内容直接丢掉。必须显式先 stop。
  void _stopRecordingIfNeeded() {
    if (!_recording) return;
    _recording = false;
    _recorder.stop().catchError((_) {});
  }

  @override
  void dispose() {
    _stopRecordingIfNeeded();
    if (AppSettings.instance.immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _flipCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _loadPresets() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('brush_presets');
    if (raw != null) {
      try {
        _presets = List<Map<String, dynamic>>.from(jsonDecode(raw));
      } catch (_) {}
    }
  }

  /// 笔盒「+」：用当前设置新建一支自定义画笔并打开编辑器（可视化/JSON 编写）。
  void _savePreset() {
    final type = _tool == Tool.brush
        ? BrushType.brush
        : _tool == Tool.highlighter
            ? BrushType.highlighter
            : _tool == Tool.pencil
                ? BrushType.pencil
                : _tool == Tool.vector
                    ? BrushType.vector
                    : _tool == Tool.rainbow
                        ? BrushType.rainbow
                        : BrushType.pen;
    final brush = CustomBrush.fromCurrent(
      'cb_${DateTime.now().microsecondsSinceEpoch}',
      '我的画笔 ${AppSettings.instance.customBrushes.length + 1}',
      type,
      _color.value,
      _size,
      _opacity,
      _highlighterFlat,
    );
    _openBrushEditor(brush);
  }

  /// 打开画笔编辑器；保存后把该笔设为当前笔。
  void _openBrushEditor(CustomBrush brush) {
    showBrushEditor(context, brush, onApplied: (b) => _applyCustomBrush(b));
  }

  /// 从笔盒预设 map 打开已有自定义画笔的编辑器。
  void _openBrushEditorForPreset(Map<String, dynamic> m) {
    final brush = AppSettings.instance.customBrushes
        .firstWhere((b) => b.id == m['id'], orElse: () => _asBrush(m));
    _openBrushEditor(brush);
  }

  void _applyPreset(Map<String, dynamic> m) {
    if (m['isCustom'] == true) {
      final brush = AppSettings.instance.customBrushes
          .firstWhere((b) => b.id == m['id'], orElse: () => _asBrush(m));
      _applyCustomBrush(brush);
      return;
    }
    setState(() {
      _tool = Tool.fromName(m['tool'] as String);
      _color = Color(m['color'] as int);
      _size = (m['size'] as num).toDouble();
      _opacity = (m['op'] as num).toDouble();
      _activeBrush = null;
      _activeBrushMeta = null;
      if (_tool == Tool.highlighter) {
        _highlighterFlat = (m['flat'] as bool? ?? false);
      }
    });
  }

  /// 由笔盒 preset map 兜底构造一支画笔（理论上不会走到，仅防御）。
  CustomBrush _asBrush(Map<String, dynamic> m) => CustomBrush.fromCurrent(
        m['id'] as String? ?? 'cb_tmp',
        (m['name'] as String?) ?? '画笔',
        BrushType.values.firstWhere(
            (t) => t.name == (m['tool'] as String), orElse: () => BrushType.pen),
        m['color'] as int? ?? 0xFF000000,
        (m['size'] as num?)?.toDouble() ?? 4.0,
        (m['op'] as num?)?.toDouble() ?? 1.0,
        (m['flat'] as bool?) ?? false,
      );

  /// 套用一支自定义画笔为当前笔：类型/颜色/粗细/透明 + 烘焙渲染参数进 meta。
  void _applyCustomBrush(CustomBrush b) {
    setState(() {
      _tool = b.type.toolOf();
      _color = Color(b.color);
      _size = b.size;
      _opacity = b.opacity;
      _highlighterFlat = b.flat;
      _activeBrush = b;
      _activeBrushMeta = b.bakedMeta();
    });
  }

  /// 落笔前合并自定义画笔参数进笔迹 meta（与荧光平头等标记共存）。
  /// 若当前工具已切到与画笔类型不符，则丢弃自定义参数，避免参数串味到别的工具。
  Map<String, dynamic>? _mergeBrushMeta(Map<String, dynamic>? base) {
    if (_activeBrushMeta == null || _activeBrush == null) return base;
    if (_activeBrush!.type.toolOf() != _tool) return base;
    return <String, dynamic>{ if (base != null) ...base, ..._activeBrushMeta! };
  }

  /// 选择工具：铅笔默认给一点通透感（石墨质感），其余保持当前透明度。
  /// 切到内置工具时清掉自定义画笔覆盖。
  void _selectTool(Tool t) {
    setState(() {
      _tool = t;
      _activeBrush = null;
      _activeBrushMeta = null;
      if (t == Tool.pencil) _opacity = 0.85;
      if (t != Tool.highlighter) _highlighterFlat = false;
    });
  }

  Future<void> _load() async {
    final n = await _store.loadNote(widget.noteId);
    if (!mounted) return; // 加载期间用户已退出编辑器
    setState(() {
      _note = n;
      if (n != null && n.pages.isNotEmpty) {
        _page = widget.initialPage.clamp(0, n.pages.length - 1);
      }
    });
  }

  Page get _cur => _note!.pages[_page];

  void _commitStroke(Stroke s) {
    final ns = Stroke(
      id: s.id,
      tool: s.tool,
      color: s.color,
      size: s.size,
      points: s.points,
      layerId: _currentLayerId,
      opacity: _opacity,
      meta: _mergeBrushMeta(s.meta),
      t: _recording ? ((DateTime.now().microsecondsSinceEpoch - (_recBase ?? 0)) ~/ 1000) : null,
    );
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(strokes: [..._cur.strokes, ns]);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    // ns 刚 append 到末尾，它的下标就是「新长度 - 1」
    _undo.add(_Hist(ns, _cur.strokes.length - 1));
    _redo.clear();
    _save();
    _growPageForUnbounded(); // 无边画布：写到边界外时把页面撑大
  }

  void _updateStrokes(List<Stroke> updated) {
    final map = {for (final s in updated) s.id: s};
    final oldIds = {for (final s in _cur.strokes) s.id};
    // 已存在的：按 id 替换为新版本；未提及的：原样保留。
    final newStrokes = _cur.strokes.map((s) => map[s.id] ?? s).toList();
    // 新增的：id 不在旧列表里（例如「区域擦除」把一笔拆成多笔时，
    // 除第一段沿用原 id 外，其余各段都是新建 id）。
    // 若只做上面的「按 id 合并」，这些新段会被静默丢弃 —— 擦完后半段凭空消失。
    // 追加在末尾即可保持绘制顺序（新段属于同一笔，叠放次序无影响）。
    for (final s in updated) {
      if (!oldIds.contains(s.id)) newStrokes.add(s);
    }
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(strokes: newStrokes);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  void _updateLayers(List<Layer> newLayers) {
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(layers: newLayers);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  void _toggleLayer(String id) {
    _updateLayers(_cur.layers
        .map((l) => l.id == id ? l.copyWith(visible: !l.visible) : l)
        .toList());
  }

  void _addLayer() {
    final id = const Uuid().v4();
    _updateLayers([
      ..._cur.layers,
      Layer(id: id, name: '图层 ${_cur.layers.length + 1}')
    ]);
    setState(() => _currentLayerId = id);
  }

  void _deleteLayer(String id) {
    if (_cur.layers.length <= 1) return;
    final newLayers = _cur.layers.where((l) => l.id != id).toList();
    final newStrokes = _cur.strokes.where((s) => s.layerId != id).toList();
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(layers: newLayers, strokes: newStrokes);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    if (_currentLayerId == id) _currentLayerId = newLayers.first.id;
    _save();
  }

  void _upsertTextBox(TextBox tb) {
    // 新文本框套用当前文本样式默认
    final styled = _cur.textBoxes.any((e) => e.id == tb.id)
        ? tb
        : tb.copyWith(
            color: _tbColor,
            fontSize: _tbSize,
            bg: _tbBg,
            border: _tbBorder,
            radius: _tbRadius,
            bold: _tbBold,
            align: _tbAlign,
          );
    final list = List<TextBox>.from(_cur.textBoxes);
    final idx = list.indexWhere((e) => e.id == styled.id);
    if (idx >= 0) {
      list[idx] = styled;
    } else {
      list.add(styled);
    }
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(textBoxes: list);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
    _growPageForUnbounded(); // 无边画布：文本框拖到边界外时把页面撑大
  }

  void _removeTextBox(String id) {
    final pages = List<Page>.from(_note!.pages);
    pages[_page] =
        _cur.copyWith(textBoxes: _cur.textBoxes.where((e) => e.id != id).toList());
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  void _removeImage(String id) {
    final pages = List<Page>.from(_note!.pages);
    pages[_page] =
        _cur.copyWith(images: _cur.images.where((e) => e.id != id).toList());
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  Future<void> _addImage() async {
    final f = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp'])
      ],
    );
    if (f == null) return;
    final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/notes/${_note!.id}');
    await dir.create(recursive: true);
    // 不用 path 包的 extension（未声明依赖），自己取后缀；
    // XFile 也没有 copy()，用 saveTo() 落盘。
    final dot = f.name.lastIndexOf('.');
    final ext = dot > 0 ? f.name.substring(dot) : '.png';
    final name = '${const Uuid().v4()}$ext';
    final dest = File('${dir.path}/$name');
    await f.saveTo(dest.path);
    final data = await dest.readAsBytes();
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final iw = fi.image.width.toDouble();
    final ih = fi.image.height.toDouble();
    final scale = iw > 0 ? 300 / iw : 1.0;
    final im = NoteImage(
      id: const Uuid().v4(),
      x: 80,
      y: 80,
      w: iw * scale,
      h: ih * scale,
      path: dest.path,
    );
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(images: [..._cur.images, im]);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  /// 图片被移动 / 缩放后回写（画布手柄拖拽时实时调用）。
  void _updateImage(NoteImage updated) {
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(
        images: _cur.images.map((e) => e.id == updated.id ? updated : e).toList());
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
    _growPageForUnbounded();
  }

  /// 无边画布（无边笔记）：内容写到页面边界之外时自动把页面撑大。
  /// 仅对开启 unbounded 的页面生效，普通页面尺寸保持固定不变。
  void _growPageForUnbounded() {
    if (!_cur.unbounded) return;
    double maxX = 0, maxY = 0;
    for (final s in _cur.strokes) {
      final b = Geometry.boundsOf(s);
      if (b.right > maxX) maxX = b.right;
      if (b.bottom > maxY) maxY = b.bottom;
    }
    for (final im in _cur.images) {
      if (im.x + im.w > maxX) maxX = im.x + im.w;
      if (im.y + im.h > maxY) maxY = im.y + im.h;
    }
    for (final tb in _cur.textBoxes) {
      if (tb.x + tb.w > maxX) maxX = tb.x + tb.w;
      if (tb.y + tb.h > maxY) maxY = tb.y + tb.h;
    }
    // 预留一段「可写空白」，保证末尾永远有地方继续下笔
    const ahead = 400.0;
    var nw = _cur.width;
    if (maxX + ahead > nw) {
      nw = (maxX + ahead) > 6000.0 ? 6000.0 : maxX + ahead;
    }
    var nh = _cur.height;
    if (maxY + ahead > nh) {
      nh = (maxY + ahead) > 20000.0 ? 20000.0 : maxY + ahead;
    }
    if (nw <= _cur.width && nh <= _cur.height) return;
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(width: nw, height: nh);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  /// 切换当前页的「无边画布」（无边笔记）。
  void _toggleUnbounded() {
    final next = !_cur.unbounded;
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(unbounded: next);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(next
            ? '无边画布已开启：可写到边界之外，页面随写随长'
            : '无边画布已关闭'),
      ));
    }
  }

  /// 缩放按钮：与 InteractiveViewer 共用同一个变换矩阵。
  void _zoomBy(double factor) {
    final cur = _viewer.value.getMaxScaleOnAxis();
    final want = cur * factor;
    final next = want > 6.0 ? 6.0 : (want < 0.4 ? 0.4 : want);
    final k = next / (cur == 0 ? 1.0 : cur);
    _viewer.value = Matrix4.diagonal3Values(k, k, 1.0) * _viewer.value;
    setState(() {});
  }

  /// 导入 Word（.docx）：正文按段落提取 + 自动折行排版后铺进新页面，
  /// 便于继续手写批注。（排版逻辑与首页「Word 新建」共享 DocxImport.buildPages。）
  Future<void> _importDocx() async {
    try {
      // 不做类型过滤：部分安卓 SAF 文件选择器对 extensions 过滤兼容差，
      // 会出现选不到 .docx 的情况；改为选完在代码里校验扩展名。
      final f = await openFile();
      if (f == null) return;
      final lower = f.name.toLowerCase();
      if (lower.endsWith('.doc') && !lower.endsWith('.docx')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('.doc 老格式不支持，请先在 Word 里另存为 .docx')));
        }
        return;
      }
      if (!lower.endsWith('.docx')) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('请选择 Word 文档（.docx）')));
        }
        return;
      }
      final paras = await DocxImport.paragraphs(f.path);
      if (paras.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('未能从该文档提取到文字')));
        }
        return;
      }
      final newPages = DocxImport.buildPages(paras);
      final pages = List<Page>.from(_note!.pages);
      pages.insertAll(_page + 1, newPages);
      _note = _note!.copyWith(
          pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
      _save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('已导入 Word：${paras.length} 段 / ${newPages.length} 页')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Word 导入失败：$e')));
      }
    }
  }

  Future<void> _showLayers() async {
    await appSheet<void>(
      context: context,
      title: '图层',
      height: 380,
      child: StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (final e in _cur.layers.asMap().entries)
                      FadeSlideIn(
                        delay: AppAnim.stagger * e.key, // 逐层错落出现
                        duration: AppAnim.fast,
                        child: ListTile(
                          leading: IconButton(
                            icon: Icon(
                                e.value.visible ? Icons.visibility : Icons.visibility_off),
                            onPressed: () {
                              _toggleLayer(e.value.id);
                              setSt(() {});
                            },
                          ),
                          title: Text(e.value.name,
                              style: TextStyle(
                                  color: _currentLayerId == e.value.id ? Colors.blue : null)),
                          onTap: () {
                            setState(() => _currentLayerId = e.value.id);
                            Navigator.pop(ctx);
                          },
                          trailing: _cur.layers.length > 1
                              ? IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () async {
                                    // 删图层会连带删掉该层上的全部笔迹（不可撤销），
                                    // 先告诉用户有多少笔要没了，不能一点就没。
                                    final n = _cur.strokes
                                        .where((s) => s.layerId == e.value.id)
                                        .length;
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (d) => AlertDialog(
                                        title: const Text('删除图层？'),
                                        content: Text(
                                            '「${e.value.name}」上的 $n 条笔迹会一起被删除，且无法用「撤销」恢复。'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(d, false),
                                              child: const Text('取消')),
                                          FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(d, true),
                                              child: const Text('删除')),
                                        ],
                                      ),
                                    );
                                    if (ok != true || !mounted) return;
                                    _deleteLayer(e.value.id);
                                    setSt(() {});
                                  },
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  _addLayer();
                  setSt(() {});
                },
                child: const Text('新增图层'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _removeStroke(Stroke s) {
    final pages = List<Page>.from(_note!.pages);
    pages[_page] =
        _cur.copyWith(strokes: _cur.strokes.where((x) => x.id != s.id).toList());
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  void _undoOp() {
    if (_undo.isEmpty || _note == null) return;
    final h = _undo.removeLast();
    // 用「当前实际下标」而不是入栈时记的下标：期间可能删过别的笔画，位置会前移。
    final idx = _cur.strokes.indexWhere((x) => x.id == h.stroke.id);
    if (idx < 0) return; // 已被别的途径删掉（切页/清页等），这条历史作废
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(
        strokes: _cur.strokes.where((x) => x.id != h.stroke.id).toList());
    _note = _note!.copyWith(pages: pages);
    _redo.add(_Hist(h.stroke, idx));
    _save();
  }

  void _redoOp() {
    if (_redo.isEmpty || _note == null) return;
    final h = _redo.removeLast();
    final list = List<Stroke>.from(_cur.strokes);
    if (list.any((x) => x.id == h.stroke.id)) return; // 已在页上，避免重复插入
    // 插回原始位置，保持叠放顺序（append 会让底层笔画盖到最上层）
    final at = h.index.clamp(0, list.length);
    list.insert(at, h.stroke);
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(strokes: list);
    _note = _note!.copyWith(pages: pages);
    _undo.add(_Hist(h.stroke, at));
    _save();
  }

  void _deletePageAt(int index) {
    if (_note!.pages.length <= 1) return;
    final pages = List<Page>.from(_note!.pages)..removeAt(index);
    int np = _page;
    if (index < _page) {
      np--;
    } else if (index == _page) {
      np = np >= pages.length ? pages.length - 1 : np;
    }
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _setPage(np);
  }

  /// 删除页面前的二次确认。
  ///
  /// 必须确认：整页删除**不在撤销栈里**（_undo 只记录笔画级的增删），
  /// 误点一下就是一整页内容永久消失，没有任何找回手段。
  /// 工具栏与页面管理器两个入口都走这里，避免只堵一处。
  Future<bool> _confirmDeletePage(int index) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一页？'),
        content: Text('第 ${index + 1} 页的全部内容会被删除，且无法用「撤销」恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deletePage() async {
    if (_note == null || _note!.pages.length <= 1) return;
    if (!await _confirmDeletePage(_page)) return;
    _deletePageAt(_page);
  }

  void _rotatePage() {
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(rotation: (_cur.rotation + 90) % 360);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  void _movePage(int from, int to) {
    if (to < 0 || to >= _note!.pages.length || from == to) return;
    final pages = List<Page>.from(_note!.pages);
    final p = pages.removeAt(from);
    pages.insert(to, p);
    _note = _note!.copyWith(
        pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    if (_page == from) {
      // 必须走 _setPage：它除了切索引，还会清空撤销/重做栈。
      // 直接改 _page 会把上一页的笔画重做到这一页（跨页污染）。
      _setPage(to); // 内部已 setState + 翻页动画
    }
    _save();
  }

  Future<void> _showJump() async {
    final ctl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转到页面'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '页码（从 1 开始）'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final n = int.tryParse(ctl.text);
              if (n != null && n >= 1 && n <= _note!.pages.length) {
                _setPage(n - 1);
              }
              Navigator.pop(ctx);
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPageManager() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text('页面管理（共 ${_note!.pages.length} 页）'),
          content: SizedBox(
            width: double.maxFinite,
            height: 440,
            child: ListView.builder(
              itemCount: _note!.pages.length,
              itemBuilder: (c, i) {
                final pg = _note!.pages[i];
                final rot = (pg.rotation / 90).round();
                final swapped = pg.rotation == 90 || pg.rotation == 270;
                final dispW = 110.0;
                final dispH = dispW * (swapped ? pg.width / pg.height : pg.height / pg.width);
                return ListTile(
                  leading: GestureDetector(
                    onTap: () => _setPage(i),
                    child: Container(
                      width: dispW,
                      height: dispH,
                      decoration: BoxDecoration(
                        border: Border.all(color: _page == i ? Colors.blue : Colors.grey),
                      ),
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: RotatedBox(
                          quarterTurns: rot,
                          child: HandwritingCanvas(
                            interactive: false,
                            strokes: pg.strokes,
                            pageW: pg.width,
                            pageH: pg.height,
                            template: pg.template,
                            paperColor: pg.paperColor,
                            layers: pg.layers,
                            textBoxes: pg.textBoxes,
                            images: pg.images,
                            tool: Tool.pen,
                            color: Colors.black,
                            size: 1,
                            onStrokeEnd: (_) {},
                            onStrokeRemoved: (_) {},
                            onStrokesUpdated: (_) {},
                            onTextBoxAdded: (_) {},
                            onTextBoxUpdated: (_) {},
                            onTextBoxRemoved: (_) {},
                            onImageAdded: (_) {},
                            onImageRemoved: (_) {},
                            onLassoCompleted: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                  title: Text('第 ${i + 1} 页'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.rotate_right),
                        tooltip: '旋转',
                        onPressed: () {
                          final pages = List<Page>.from(_note!.pages);
                          pages[i] = pg.copyWith(rotation: (pg.rotation + 90) % 360);
                          _note = _note!.copyWith(pages: pages);
                          setSt(() {});
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: '前移',
                        onPressed: i > 0
                            ? () {
                                _movePage(i, i - 1);
                                setSt(() {});
                              }
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        tooltip: '后移',
                        onPressed: i < _note!.pages.length - 1
                            ? () {
                                _movePage(i, i + 1);
                                setSt(() {});
                              }
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        tooltip: '删除',
                        onPressed: _note!.pages.length > 1
                            ? () async {
                                if (!await _confirmDeletePage(i)) return;
                                if (!mounted) return;
                                _deletePageAt(i);
                                setSt(() {});
                              }
                            : null,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _save();
                Navigator.pop(ctx);
              },
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageTile(int i, double maxW) {
    final pg = _note!.pages[i];
    final rot = (pg.rotation / 90).round();
    final swapped = pg.rotation == 90 || pg.rotation == 270;
    final dispH = maxW * (swapped ? pg.width / pg.height : pg.height / pg.width);
    return GestureDetector(
      onTap: () => _setPage(i),
      child: Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300)),
        child: SizedBox(
          width: maxW,
          height: dispH,
          child: FittedBox(
            fit: BoxFit.contain,
            child: RotatedBox(
              quarterTurns: rot,
              child: HandwritingCanvas(
                interactive: false,
                strokes: pg.strokes,
                pageW: pg.width,
                pageH: pg.height,
                template: pg.template,
                paperColor: pg.paperColor,
                layers: pg.layers,
                textBoxes: pg.textBoxes,
                images: pg.images,
                tool: Tool.pen,
                color: Colors.black,
                size: 1,
                onStrokeEnd: (_) {},
                onStrokeRemoved: (_) {},
                onStrokesUpdated: (_) {},
                onTextBoxAdded: (_) {},
                onTextBoxUpdated: (_) {},
                onTextBoxRemoved: (_) {},
                onImageAdded: (_) {},
                onImageRemoved: (_) {},
                onLassoCompleted: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadingView() {
    if (_readingMode == 1) {
      return ListView.builder(
        itemCount: _note!.pages.length,
        itemBuilder: (c, i) => _pageTile(i, 360),
      );
    }
    return ListView.builder(
      itemCount: (_note!.pages.length + 1) ~/ 2,
      itemBuilder: (c, i) {
        final a = i * 2;
        final b = a + 1;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _pageTile(a, 180)),
            if (b < _note!.pages.length) Expanded(child: _pageTile(b, 180)),
          ],
        );
      },
    );
  }

  /// 阅读模式开关：进入=连续滚动(1)，退出=单页编辑(0)，一次点按即可退出。
  /// 修正：原先 0→1→2→0 三态循环，从「连续(1)」退出需点两次（先到双页再回到单页）。
  void _toggleReading() {
    setState(() {
      _readingMode = _readingMode == 0 ? 1 : 0;
    });
  }

  Future<void> _save() async {
    await _store.saveNote(_note!);
    if (AppSettings.instance.autoBackup) {
      try {
        // 走节流入口：每笔都整库打包会把磁盘吃满并明显卡顿
        await Backup.backupThrottled();
      } catch (_) {}
    }
    // await 之后 widget 可能已被销毁（退出编辑器），必须判 mounted 再 setState
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _showTemplateMenu() async {
    final choice = await showDialog<PageTemplate>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('页面模板'),
        children: PageTemplate.values
            .map((t) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, t),
                  child: Text(_tplName(t)),
                ))
            .toList(),
      ),
    );
    if (choice != null && _note != null) {
      setState(() => _note!.pages[_page] = _cur.copyWith(template: choice));
      await _save();
    }
  }

  String _tplName(PageTemplate t) {
    switch (t) {
      case PageTemplate.none:
        return '空白';
      case PageTemplate.grid:
        return '网格';
      case PageTemplate.line:
        return '横线';
      case PageTemplate.dot:
        return '点阵';
      case PageTemplate.cornell:
        return '康奈尔笔记';
      case PageTemplate.week:
        return '周计划';
      case PageTemplate.month:
        return '月历';
      case PageTemplate.todos:
        return '待办清单';
      case PageTemplate.checklist:
        return '检查清单';
      case PageTemplate.math:
        return '数学方格';
      case PageTemplate.music:
        return '五线谱';
      case PageTemplate.column2:
        return '双栏';
      case PageTemplate.column3:
        return '三栏';
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // ---------- 文字识别（离线 OCR） ----------
  Future<void> _ocr() async {
    if (_note == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('识别文字（离线）'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'page'),
            child: const Text('整页识别（图片 + 文本框 + 笔迹）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'strokes'),
            child: const Text('只识别手写笔迹（去底纹，更准）'),
          ),
          if (_cur.images.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'image'),
              child: Text('识别页内图片（共 ${_cur.images.length} 张）'),
            ),
        ],
      ),
    );
    if (choice == null) return;

    String? imgPath;
    if (choice == 'image') {
      imgPath = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择要识别的图片'),
          children: [
            for (int i = 0; i < _cur.images.length; i++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, _cur.images[i].path),
                child: Text('图片 ${i + 1}'),
              ),
          ],
        ),
      );
      if (imgPath == null) return;
    }

    if (!mounted) return;
    final script = AppSettings.instance.ocrScript;
    final eye = AppSettings.instance.themeMode == AppThemeMode.eyeCare;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 18),
            Expanded(child: Text('识别中…')),
          ],
        ),
      ),
    );

    OcrResult r;
    try {
      if (choice == 'page') {
        r = await OcrService.recognizePage(_note!, _page,
            script: script, eyeCare: eye);
      } else if (choice == 'strokes') {
        r = await OcrService.recognizeStrokes(_note!, _page, script: script);
      } else {
        r = await OcrService.recognizeFile(imgPath!, script: script);
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // 关闭进度框
      _toast('识别失败：$e');
      return;
    }
    if (mounted) Navigator.pop(context); // 关闭进度框
    if (!mounted) return;

    if (r.isEmpty) {
      _toast('没识别到文字（手写太连笔或内容为空时会这样）');
      return;
    }

    // 整页/笔迹识别自动写入搜索索引
    if (choice != 'image') {
      await OcrIndex.putPage(_note!.id, _page, r.text);
    }
    if (!mounted) return;

    final inserted = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => OcrPage(
          result: r,
          noteId: _note!.id,
          pageIndex: _page,
        ),
      ),
    );
    if (inserted != null && inserted.trim().isNotEmpty) {
      _upsertTextBox(TextBox(
        id: const Uuid().v4(),
        x: 32,
        y: 32,
        w: (_cur.width - 64).clamp(120.0, 1600.0),
        h: 220,
        text: inserted,
      ));
      _toast('已插入为文本框');
    }
  }

  Future<void> _export() async {
    if (_note == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出 / 分享'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _expTile(Icons.picture_as_pdf, '导出 PDF（整本）',
                  () => Navigator.pop(ctx, 'pdf')),
              _expTile(Icons.share, '分享 PDF（整本）',
                  () => Navigator.pop(ctx, 'pdfshare')),
              _expTile(Icons.image, '当前页 → PNG',
                  () => Navigator.pop(ctx, 'png1')),
              _expTile(Icons.image, '当前页 → JPG',
                  () => Navigator.pop(ctx, 'jpg1')),
              _expTile(Icons.photo_library, '整本 → PNG（多文件）',
                  () => Navigator.pop(ctx, 'pngall')),
              _expTile(Icons.photo_library, '整本 → JPG（多文件）',
                  () => Navigator.pop(ctx, 'jpgall')),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    final eye = AppSettings.instance.themeMode == AppThemeMode.eyeCare;
    try {
      final title = _safeName(_note!.title);
      if (choice == 'pdfshare') {
        // 走系统分享面板，可直接发到微信 / 邮件等；不依赖文件管理器可见性
        final bytes = await PdfExport.exportBytes(_note!, eyeCare: eye);
        await Printing.sharePdf(bytes: bytes, filename: '$title.pdf');
        _toast('已唤起系统分享');
        return;
      }
      // file_selector 的 saveFile / getDirectoryPath 在 Android 上不可用，
      // 统一导出到「下载 / HydroNote」目录（Android 11+ 文件管理器可见），
      // 取不到再回退应用专属目录。
      final outDir = await _exportDir();
      if (choice == 'pdf') {
        final out = '$outDir/$title.pdf';
        await PdfExport.export(_note!, out, eyeCare: eye);
        _toast('已导出：$out');
      } else {
        final f = choice.startsWith('png') ? ImageFormat.png : ImageFormat.jpg;
        final all = choice.endsWith('all');
        if (all) {
          final sub = Directory('$outDir/${title}_${f.ext}');
          await sub.create(recursive: true);
          final paths = await ImageExport.exportAll(_note!, f, sub.path, eyeCare: eye);
          _toast('已导出 ${paths.length} 张到 ${sub.path}');
        } else {
          final out = '$outDir/${title}_p${_page + 1}.${f.ext}';
          await ImageExport.exportPage(_note!, _page, f, out, eyeCare: eye);
          _toast('已导出：$out');
        }
      }
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Widget _expTile(IconData ic, String label, VoidCallback on) => ListTile(
        leading: Icon(ic),
        title: Text(label),
        onTap: on,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );

  /// 导出目录：优先「下载 / HydroNote」（Android 文件管理器可见），
  /// 取不到则回退应用专属外部存储，再不行用应用文档目录。
  Future<String> _exportDir() async {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      base = null;
    }
    base ??= await getExternalStorageDirectory();
    base ??= await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/HydroNote');
    await d.create(recursive: true);
    return d.path;
  }

  /// 文件名去掉非法字符
  String _safeName(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  // ---------- 左侧竖排工具盘 ----------
  Widget _rail([double width = 58]) {
    final tools = [
      (Tool.pen, FluentIcons.pen_24_regular, FluentIcons.pen_24_filled),
      (Tool.brush, FluentIcons.paint_brush_24_regular, FluentIcons.paint_brush_24_filled),
      (Tool.highlighter, FluentIcons.highlight_24_regular, FluentIcons.highlight_24_filled),
      (Tool.pencil, null, null), // 铅笔（批次18）
      (Tool.rainbow, null, null), // 彩虹笔（批次18）
      (Tool.vector, null, null), // 矢量笔（批次18）
      (Tool.smartPen, null, null), // 智能钢笔（z_math 变宽笔迹）
      (Tool.tape, null, null),
      (Tool.eraser, FluentIcons.eraser_24_regular, FluentIcons.eraser_24_filled),
      (Tool.laser, null, null),
      (Tool.line, FluentIcons.line_24_regular, FluentIcons.line_24_filled),
      (Tool.rect, FluentIcons.rectangle_landscape_24_regular, FluentIcons.rectangle_landscape_24_filled),
      (Tool.ellipse, FluentIcons.circle_24_regular, FluentIcons.circle_24_filled),
      // fluentui_system_icons 1.1.1 无三角形图标，用 Material 兜底
      (Tool.triangle, null, null),
      (Tool.arrow, FluentIcons.arrow_next_24_regular, FluentIcons.arrow_next_24_filled),
      (Tool.lasso, null, null),
      // fluentui_system_icons 1.1.1 里没有 text_24_*，用 Material 图标兜底
      (Tool.text, null, null),
    ];
    final isLeft = AppSettings.instance.leftHand;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        // 与画布相邻的边做圆角，手机窄屏不再像硬切的方条
        borderRadius: isLeft
            ? const BorderRadius.only(
                topLeft: Radius.circular(16), bottomLeft: Radius.circular(16))
            : const BorderRadius.only(
                topRight: Radius.circular(16), bottomRight: Radius.circular(16)),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final t in tools)
              _railBtn(
                icon: t.$2 != null ? flu(t.$2!, t.$3!) : Icon(_railMatIcon(t.$1)),
                tooltip: _toolName(t.$1),
                selected: _tool == t.$1,
                onTap: () => _selectTool(t.$1),
              ),
            _railBtn(
              icon: const Icon(Icons.image),
              tooltip: '插入图片',
              onTap: _addImage,
            ),
            _railBtn(
              icon: const Icon(Icons.crop),
              tooltip: '图片裁剪',
              onTap: _showImageSheet,
            ),
            _railBtn(
              // fluentui_system_icons 1.1.1 无 brush_24_*，用 Material 图标
              icon: const Icon(Icons.brush),
              tooltip: '我的笔盒（悬浮窗，可拖动）',
              onTap: _openPenBox,
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部 AppBar 按钮：统一按压缩放反馈；
  /// `turns` 用于撤销 / 重做这类需要旋转动效的按钮。
  Widget _abtn({
    required Widget icon,
    String? tooltip,
    VoidCallback? onPressed,
    VoidCallback? onLongPress,
    Color? color,
    double turns = 0,
  }) =>
      AnimatedRotation(
        turns: turns,
        duration: AppAnim.normal,
        curve: AppAnim.spring,
        child: PressScale(
          enabled: onPressed != null,
          onLongPress: onLongPress,
          child: IconButton(
            icon: icon,
            tooltip: tooltip,
            color: color,
            onPressed: onPressed,
          ),
        ),
      );

  /// 顶部工具栏：宽屏（>=720）全部内联；窄屏只保留主操作，其余收进「⋯」菜单，避免溢出。
  List<Widget> _appBarActions(bool wide) {
    final primary = <Widget>[
      _abtn(
        icon: flu(FluentIcons.arrow_undo_24_regular,
            FluentIcons.arrow_undo_24_filled),
        tooltip: '撤销',
        turns: _undoTurns,
        onPressed: () => setState(() {
          _undoTurns -= 1;
          _undoOp();
        }),
      ),
      _abtn(
        icon: flu(FluentIcons.arrow_redo_24_regular,
            FluentIcons.arrow_redo_24_filled),
        tooltip: '重做',
        turns: _redoTurns,
        onPressed: () => setState(() {
          _redoTurns += 1;
          _redoOp();
        }),
      ),
      _abtn(
        icon: flu(FluentIcons.chevron_left_24_regular,
            FluentIcons.chevron_left_24_filled),
        tooltip: '上一页',
        onPressed: _page > 0 ? () => _setPage(_page - 1) : null,
      ),
      _abtn(
        icon: flu(FluentIcons.chevron_right_24_regular,
            FluentIcons.chevron_right_24_filled),
        tooltip: '下一页',
        onPressed: _page < _note!.pages.length - 1
            ? () => _setPage(_page + 1)
            : null,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: AnimatedSwitcher(
            duration: AppAnim.fast,
            child: Text(
              '${_page + 1}/${_note!.pages.length}',
              key: ValueKey(_page),
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
      _abtn(
        icon: flu(FluentIcons.save_24_regular, FluentIcons.save_24_filled),
        tooltip: '导出 / 分享',
        onPressed: _export,
      ),
    ];
    if (wide) {
      return [
        ...primary,
        _abtn(
          icon: SwitchFade(
            slide: false,
            child: Icon(
              _readingMode == 0
                  ? Icons.article_outlined
                  : _readingMode == 1
                      ? Icons.view_agenda
                      : Icons.view_column,
              key: ValueKey(_readingMode),
            ),
          ),
          tooltip: '阅读模式（点按进入/退出；长按切双页）',
          onPressed: _toggleReading,
          onLongPress: () => setState(() => _readingMode = 2),
        ),
        _abtn(
          icon: const Icon(Icons.grid_on),
          tooltip: '页面模板',
          onPressed: _showTemplateMenu,
        ),
        _abtn(
          icon: const Icon(Icons.palette),
          tooltip: '纸张配色',
          onPressed: _setPaperColor,
        ),
        _abtn(
          icon: AnimatedRotation(
            turns: _cur.rotation / 360,
            duration: AppAnim.normal,
            curve: AppAnim.curve,
            child: const Icon(Icons.rotate_right),
          ),
          tooltip: '旋转当前页',
          onPressed: _rotatePage,
        ),
        _abtn(
          icon: const Icon(Icons.delete),
          tooltip: '删除当前页',
          onPressed: _note!.pages.length > 1 ? () => _deletePage() : null,
        ),
        _abtn(
          icon: Icon(_panMode ? Icons.pan_tool : Icons.draw),
          tooltip: _panMode ? '拖动模式（点此回到书写）' : '书写模式（点此切拖动页面）',
          color: _panMode ? Theme.of(context).colorScheme.primary : null,
          onPressed: () => setState(() => _panMode = !_panMode),
        ),
        _abtn(
          icon: Icon(_cur.unbounded ? Icons.crop_free : Icons.crop_square),
          tooltip: _cur.unbounded ? '无边画布（已开）' : '无边画布（页面随写随长）',
          color: _cur.unbounded ? Theme.of(context).colorScheme.primary : null,
          onPressed: _toggleUnbounded,
        ),
        _abtn(
          icon: const Icon(Icons.description),
          tooltip: '导入 Word',
          onPressed: _importDocx,
        ),
        _abtn(
          icon: const Icon(Icons.zoom_out),
          tooltip: '缩小',
          onPressed: () => _zoomBy(1 / 1.25),
        ),
        _abtn(
          icon: const Icon(Icons.zoom_in),
          tooltip: '放大',
          onPressed: () => _zoomBy(1.25),
        ),
        _abtn(
          icon: const Icon(Icons.layers),
          tooltip: '图层',
          onPressed: _showLayers,
        ),
        _abtn(
          icon: Pulse(
            enabled: _recording,
            child: flu(FluentIcons.mic_24_regular, FluentIcons.mic_24_filled),
          ),
          tooltip: _recording ? '停止录音' : '录音',
          color: _recording ? Colors.red : null,
          onPressed: _toggleRecord,
        ),
        if (_note!.audioPath != null)
          _abtn(
            icon: flu(FluentIcons.play_24_regular, FluentIcons.play_24_filled),
            tooltip: '音频回放',
            onPressed: _playback,
          ),
        _abtn(
          icon: flu(FluentIcons.book_24_regular, FluentIcons.book_24_filled),
          tooltip: '闪卡',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => FlashcardPage(widget.noteId)),
          ),
        ),
        if (OcrService.available)
          _abtn(
            icon: const Icon(Icons.text_snippet_outlined),
            tooltip: '识别文字（离线 OCR）',
            onPressed: _ocr,
          ),
        _abtn(
          icon: const Icon(Icons.format_list_numbered),
          tooltip: '跳转页面',
          onPressed: _showJump,
        ),
        _abtn(
          icon: const Icon(Icons.view_module),
          tooltip: '页面管理',
          onPressed: _showPageManager,
        ),
      ];
    }
    return [
      ...primary,
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        tooltip: '更多',
        itemBuilder: (ctx) => <PopupMenuEntry<String>>[
          PopupMenuItem(value: 'reading', child: _mi(Icons.article_outlined, '阅读模式')),
          PopupMenuItem(value: 'reading2', child: _mi(Icons.view_column, '双页阅读')),
          PopupMenuItem(
              value: 'pan',
              child: _mi(Icons.pan_tool,
                  _panMode ? '拖动模式（已开启）' : '拖动页面模式')),
          PopupMenuItem(
              value: 'unb',
              child: _mi(Icons.crop_free,
                  _cur.unbounded ? '无边画布（已开启）' : '无边画布')),
          PopupMenuItem(
              value: 'docx', child: _mi(Icons.description, '导入 Word')),
          PopupMenuItem(value: 'template', child: _mi(Icons.grid_on, '页面模板')),
          PopupMenuItem(value: 'paper', child: _mi(Icons.palette, '纸张配色')),
          PopupMenuItem(value: 'rotate', child: _mi(Icons.rotate_right, '旋转当前页')),
          PopupMenuItem(value: 'del', child: _mi(Icons.delete, '删除当前页')),
          PopupMenuItem(value: 'zout', child: _mi(Icons.zoom_out, '缩小')),
          PopupMenuItem(value: 'zin', child: _mi(Icons.zoom_in, '放大')),
          PopupMenuItem(value: 'layers', child: _mi(Icons.layers, '图层')),
          PopupMenuItem(value: 'rec', child: _mi(FluentIcons.mic_24_regular, '录音')),
          if (_note!.audioPath != null)
            PopupMenuItem(value: 'play', child: _mi(FluentIcons.play_24_regular, '音频回放')),
          PopupMenuItem(value: 'fc', child: _mi(FluentIcons.book_24_regular, '闪卡')),
          if (OcrService.available)
            PopupMenuItem(value: 'ocr', child: _mi(Icons.text_snippet_outlined, '识别文字')),
          PopupMenuItem(value: 'jump', child: _mi(Icons.format_list_numbered, '跳转页面')),
          PopupMenuItem(value: 'pages', child: _mi(Icons.view_module, '页面管理')),
        ],
        onSelected: _onSecondary,
      ),
    ];
  }

  Widget _mi(IconData ic, String label) =>
      Row(children: [Icon(ic, size: 20), const SizedBox(width: 12), Text(label)]);

  void _onSecondary(String v) {
    switch (v) {
      case 'reading':
        _toggleReading();
        break;
      case 'reading2':
        setState(() => _readingMode = 2);
        break;
      case 'pan':
        setState(() => _panMode = !_panMode);
        break;
      case 'unb':
        _toggleUnbounded();
        break;
      case 'docx':
        _importDocx();
        break;
      case 'template':
        _showTemplateMenu();
        break;
      case 'paper':
        _setPaperColor();
        break;
      case 'rotate':
        _rotatePage();
        break;
      case 'del':
        if (_note!.pages.length > 1) _deletePage();
        break;
      case 'zout':
        if (_zoom > 0.5) setState(() => _zoom -= 0.2);
        break;
      case 'zin':
        if (_zoom < 3.0) setState(() => _zoom += 0.2);
        break;
      case 'layers':
        _showLayers();
        break;
      case 'rec':
        _toggleRecord();
        break;
      case 'play':
        _playback();
        break;
      case 'fc':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => FlashcardPage(widget.noteId)));
        break;
      case 'ocr':
        _ocr();
        break;
      case 'jump':
        _showJump();
        break;
      case 'pages':
        _showPageManager();
        break;
    }
  }

  /// 工具盘按钮：按下缩放 + 选中态背景/图标放大（统一动画参数）
  Widget _railBtn({
    required Widget icon,
    required String tooltip,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: PressScale(
        scale: 0.85,
        tooltip: tooltip,
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppAnim.normal,
          curve: AppAnim.curve,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: AnimatedScale(
            scale: selected ? 1.12 : 1.0,
            duration: AppAnim.normal,
            curve: AppAnim.spring,
            child: IconTheme(
              data: IconThemeData(
                color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                size: 22,
              ),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }

  static String _toolName(Tool t) => const {
        Tool.pen: '钢笔',
        Tool.brush: '毛笔',
        Tool.highlighter: '荧光笔',
        Tool.pencil: '铅笔',
        Tool.rainbow: '彩虹笔',
        Tool.vector: '矢量笔',
        Tool.smartPen: '智能钢笔',
        Tool.eraser: '橡皮',
        Tool.tape: '胶带笔',
        Tool.laser: '激光笔',
        Tool.line: '直线',
        Tool.rect: '矩形',
        Tool.ellipse: '椭圆',
        Tool.triangle: '三角形',
        Tool.arrow: '箭头',
        Tool.lasso: '套索',
        Tool.text: '文本',
      }[t]!;

  IconData _railMatIcon(Tool t) {
    switch (t) {
      case Tool.laser:
        return Icons.gesture;
      case Tool.lasso:
        return Icons.select_all;
      case Tool.text:
        return Icons.text_fields;
      case Tool.tape:
        return Icons.line_weight;
      case Tool.triangle:
        return Icons.change_history;
      case Tool.pencil:
        return Icons.edit;
      case Tool.rainbow:
        return Icons.gradient;
      case Tool.vector:
        return Icons.timeline;
      case Tool.smartPen:
        return Icons.auto_fix_high;
      default:
        return Icons.circle;
    }
  }

  // ---------- 顶部动态属性面板 ----------
  Widget _propertyPanel() {
    final children = <Widget>[];
    if (_tool == Tool.eraser) {
      children.add(_seg('整笔', 0));
      children.add(_seg('像素', 1));
      children.add(_seg('荧光', 2));
    } else if (_tool.isLasso) {
      // 套索：自由圈选 / 矩形框选（方框选择）
      children.add(_lassoSeg('自由圈选', false));
      children.add(_lassoSeg('矩形框选', true));
    } else if (_tool.isText) {
      children.add(_colorBtn());
      children.add(_slider('大小', _tbSize, 8, 48, (v) => setState(() => _tbSize = v)));
      children.add(_chk('粗体', _tbBold, (v) => setState(() => _tbBold = v)));
      children.add(_alignSeg());
      children.add(IconButton(
        icon: const Icon(Icons.format_color_fill),
        tooltip: '背景色',
        onPressed: () => _pickText(useBg: true),
      ));
      children.add(IconButton(
        icon: const Icon(Icons.border_color),
        tooltip: '边框色',
        onPressed: () => _pickText(useBg: false),
      ));
      children.add(_slider('圆角', _tbRadius, 0, 24, (v) => setState(() => _tbRadius = v)));
    } else if (_tool.isLaser) {
      children.add(const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text('激光笔：临时高亮，不落笔', style: TextStyle(color: Colors.red)),
      ));
    } else {
      children.add(_colorBtn());
      children.add(_slider('粗细', _size, 1, 30, (v) => setState(() => _size = v)));
      if (_tool == Tool.highlighter) {
        // 荧光笔圆头 / 平头（平头走 freehand cap=false，方头效果）
        children.add(_seg2('圆头', false, _highlighterFlat));
        children.add(_seg2('平头', true, _highlighterFlat));
      }
      // 形状工具同样要显示「透明」：它落笔时用的是同一个 _opacity，
      // 但面板上不显示 —— 用户调低过（荧光笔常用 0.85 甚至更低）再切到矩形，
      // 画出来的形状就淡到几乎看不见，而面板上没有任何线索可查。
      children.add(_slider('透明', _opacity, 0.1, 1, (v) => setState(() => _opacity = v)));
    }
    // 笔盒已改为悬浮窗（可拖动），这里只保留一个打开入口
    final cs = Theme.of(context).colorScheme;
    children.add(const VerticalDivider());
    children.add(PressScale(
      tooltip: '我的笔盒（悬浮窗，可拖动）',
      onTap: _openPenBox,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primary.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.brush, size: 16, color: cs.primary),
            const SizedBox(width: 4),
            Text('笔盒 ${_presets.length}',
                style: TextStyle(fontSize: 12, color: cs.primary)),
          ],
        ),
      ),
    ));
    // 切换工具时整条属性栏交叉淡入，避免内容"啪"地跳变
    return Container(
      height: 60,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.92),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SwitchFade(
        axis: Axis.horizontal,
        child: SingleChildScrollView(
          key: ValueKey(_tool),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: children),
        ),
      ),
    );
  }

  Widget _seg(String label, int v) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: _eraserMode == v,
          onSelected: (_) => setState(() => _eraserMode = v),
        ),
      );

  /// 套索方式：自由圈选 / 矩形框选（方框选择）。
  Widget _lassoSeg(String label, bool rect) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: _rectLasso == rect,
          onSelected: (_) => setState(() => _rectLasso = rect),
        ),
      );

  /// 布尔二选一片段（如荧光笔 圆头/平头）
  Widget _seg2(String label, bool val, bool cur) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: cur == val,
          onSelected: (_) => setState(() => _highlighterFlat = val),
        ),
      );

  Widget _slider(String label, double value, double min, double max, void Function(double) on) =>
      Row(children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        SizedBox(
          width: 110,
          child: Slider(value: value, min: min, max: max, onChanged: on),
        ),
      ]);

  Widget _chk(String label, bool v, void Function(bool) on) => Row(children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        Checkbox(value: v, onChanged: (x) => on(x ?? false)),
      ]);

  Widget _alignSeg() => Row(children: [
        IconButton(
          icon: const Icon(Icons.format_align_left),
          color: _tbAlign == 0 ? Colors.blue : null,
          onPressed: () => setState(() => _tbAlign = 0),
        ),
        IconButton(
          icon: const Icon(Icons.format_align_center),
          color: _tbAlign == 1 ? Colors.blue : null,
          onPressed: () => setState(() => _tbAlign = 1),
        ),
        IconButton(
          icon: const Icon(Icons.format_align_right),
          color: _tbAlign == 2 ? Colors.blue : null,
          onPressed: () => setState(() => _tbAlign = 2),
        ),
      ]);

  Widget _colorBtn() {
    return IconButton(
      icon: const Icon(Icons.palette),
      tooltip: '选择颜色',
      onPressed: () async {
        final hex = await showDialog<String>(
          context: context,
          builder: (ctx) => const PaletteDialog(),
        );
        if (hex != null) {
          final c = Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
          setState(() => _color = c);
        }
      },
    );
  }

  Future<void> _pickText({required bool useBg}) async {
    final palette = [
      Colors.yellow,
      Colors.green,
      Colors.blue,
      Colors.pink,
      Colors.orange,
      Colors.white
    ];
    final c = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(useBg ? '背景色' : '边框色'),
        content: Wrap(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(ctx, null),
              child: Container(
                margin: const EdgeInsets.all(4),
                width: 36,
                height: 36,
                color: Colors.grey.shade300,
                child: const Icon(Icons.block),
              ),
            ),
            for (final col in palette)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, col.value),
                child: Container(
                    margin: const EdgeInsets.all(4), width: 36, height: 36, color: col),
              ),
          ],
        ),
      ),
    );
    setState(() {
      if (useBg) {
        _tbBg = c;
      } else {
        _tbBorder = c;
      }
    });
  }

  /// 当前笔刷快照：传给悬浮笔盒用于高亮命中的预设
  /// 笔盒高亮用的「当前笔」map：自定义画笔优先用其预设 map。
  Map<String, dynamic> get _currentBrush => _activeBrush != null
      ? _activeBrush!.toPresetMap()
      : {
          'tool': _tool.name,
          'color': _color.value,
          'size': _size,
          'op': _opacity,
          'flat': _highlighterFlat,
        };

  /// 笔盒预设列表 = 自定义画笔(在前) + 旧版收藏夹预设。
  List<Map<String, dynamic>> get _penBoxPresets {
    final custom =
        AppSettings.instance.customBrushes.map((b) => b.toPresetMap()).toList();
    return [...custom, ..._presets];
  }

  /// 删除笔盒中的预设（自定义画笔走编辑器删除，这里只处理旧版收藏夹）。
  Future<void> _deletePreset(Map<String, dynamic> m) async {
    if (m['isCustom'] == true) return;
    final idx = _presets.indexWhere((x) => FloatingPenBoxState.same(x, m));
    if (idx < 0) return;
    setState(() => _presets.removeAt(idx));
    final p = await SharedPreferences.getInstance();
    await p.setString('brush_presets', jsonEncode(_presets));
  }

  // ---------- 纸张配色 ----------
  Future<void> _setPaperColor() async {
    final palette = [
      Colors.white,
      const Color(0xFFF5ECD7),
      const Color(0xFFE8F5E9),
      const Color(0xFFE3F2FD),
      const Color(0xFFFFF3E0),
      const Color(0xFFFCE4EC),
      Colors.amber.shade100,
    ];
    final c = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('纸张配色'),
        content: Wrap(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(ctx, null),
              child: Container(
                margin: const EdgeInsets.all(4),
                width: 40,
                height: 40,
                color: Colors.grey.shade300,
                child: const Icon(Icons.block),
              ),
            ),
            for (final col in palette)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, col.value),
                child: Container(
                    margin: const EdgeInsets.all(4), width: 40, height: 40, color: col),
              ),
          ],
        ),
      ),
    );
    setState(() => _note!.pages[_page] = _cur.copyWith(paperColor: c));
    await _save();
  }

  // ---------- 图片裁剪 ----------
  Future<void> _showImageSheet() async {
    if (_cur.images.isEmpty) {
      _toast('当前页还没有图片');
      return;
    }
    await appSheet<void>(
      context: context,
      title: '图片',
      height: 320,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ListView(
          children: [
            for (final e in _cur.images.asMap().entries)
              FadeSlideIn(
                delay: AppAnim.stagger * e.key,
                duration: AppAnim.fast,
                child: Builder(
                  builder: (ctx) {
                    final im = e.value;
                    return ListTile(
                      leading: const Icon(Icons.image),
                      title: Text('图片 ${e.key + 1}'),
                      subtitle: Text(im.crop != null ? '已裁剪' : '未裁剪'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.crop),
                            tooltip: '矩形裁剪',
                            onPressed: () {
                              Navigator.pop(ctx);
                              _cropImageDialog(im);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.gesture),
                            tooltip: '自由裁剪',
                            onPressed: () {
                              Navigator.pop(ctx);
                              _startFreeCrop(im);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.restart_alt),
                            tooltip: '重置裁剪',
                            onPressed: () {
                              // 重置：显示矩形还原成整张图，crop 清空
                              // （copyWith 的 clearCrop 才能真正把 null 写进去）
                              final full = _fullScreenRect(im);
                              _updateImageCrop(
                                im.copyWith(
                                    x: full.left,
                                    y: full.top,
                                    w: full.width,
                                    h: full.height),
                                null,
                              );
                              Navigator.pop(ctx);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 源图「完整一整张」当前在屏幕上占的矩形。
  ///
  /// 绘制语义（屏幕与两条导出路径一致）：把源图上 crop 划出的那块，
  /// 拉伸绘制到 (im.x, im.y, im.w, im.h)。所以由当前 crop 与当前显示矩形
  /// 可以反推出整张图在屏幕上的位置与尺寸，进而把任意源图区域换算成屏幕矩形。
  ///
  /// 没有这一步的话，裁剪只改了取图的源区域、显示框却纹丝不动 ——
  /// 裁下来的小块会被拉伸回原来的大框（越裁越大），完全不是裁剪该有的行为。
  Rect _fullScreenRect(NoteImage im) {
    final ow = im.crop?['sw'] ?? 1.0;
    final oh = im.crop?['sh'] ?? 1.0;
    if (ow <= 0 || oh <= 0) return Rect.fromLTWH(im.x, im.y, im.w, im.h);
    final ox = im.crop?['sx'] ?? 0.0;
    final oy = im.crop?['sy'] ?? 0.0;
    final fw = im.w / ow;
    final fh = im.h / oh;
    return Rect.fromLTWH(im.x - ox * fw, im.y - oy * fh, fw, fh);
  }

  /// [im] 携带裁剪后的新显示矩形，[crop] 是源图上的归一化区域（null=不裁剪）。
  void _updateImageCrop(NoteImage im, Map<String, double>? crop) {
    final list = _cur.images
        .map((e) => e.id == im.id
            ? im.copyWith(crop: crop, clearCrop: crop == null)
            : e)
        .toList();
    final pages = List<Page>.from(_note!.pages);
    pages[_page] = _cur.copyWith(images: list);
    _note = _note!.copyWith(pages: pages, updatedAt: DateTime.now().millisecondsSinceEpoch);
    _save();
  }

  Future<void> _cropImageDialog(NoteImage im) async {
    var sx = (im.crop?['sx'] ?? 0.0);
    var sy = (im.crop?['sy'] ?? 0.0);
    var sw = (im.crop?['sw'] ?? 1.0);
    var sh = (im.crop?['sh'] ?? 1.0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('矩形裁剪（占原图比例）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _cropSlider('X', sx, (v) => setD(() => sx = v)),
              _cropSlider('Y', sy, (v) => setD(() => sy = v)),
              _cropSlider('宽', sw, (v) => setD(() => sw = v)),
              _cropSlider('高', sh, (v) => setD(() => sh = v)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () {
                if (sx + sw > 1) sw = 1 - sx;
                if (sy + sh > 1) sh = 1 - sy;
                if (sw <= 0 || sh <= 0) {
                  Navigator.pop(ctx, false);
                  return;
                }
                // 显示矩形同步收缩到裁出的那块，否则裁完反而被拉伸放大
                final full = _fullScreenRect(im);
                final rect = Rect.fromLTWH(
                  full.left + sx * full.width,
                  full.top + sy * full.height,
                  sw * full.width,
                  sh * full.height,
                );
                _updateImageCrop(
                  im.copyWith(
                      x: rect.left,
                      y: rect.top,
                      w: rect.width,
                      h: rect.height),
                  {'sx': sx, 'sy': sy, 'sw': sw, 'sh': sh},
                );
                Navigator.pop(ctx, true);
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) _save();
  }

  Widget _cropSlider(String label, double v, void Function(double) on) => Row(children: [
        Text(label),
        Expanded(child: Slider(value: v, min: 0, max: 1, onChanged: on)),
        Text(v.toStringAsFixed(2)),
      ]);

  void _startFreeCrop(NoteImage im) {
    setState(() {
      _cropPendingImage = im;
      _tool = Tool.lasso;
    });
    _toast('在图片上自由圈选，松开即裁剪');
  }

  void _applyFreeCrop(List<Offset> poly) {
    if (_cropPendingImage == null) return;
    double minX = double.infinity, minY = double.infinity,
        maxX = -double.infinity, maxY = -double.infinity;
    for (final p in poly) {
      minX = minX < p.dx ? minX : p.dx;
      minY = minY < p.dy ? minY : p.dy;
      maxX = maxX > p.dx ? maxX : p.dx;
      maxY = maxY > p.dy ? maxY : p.dy;
    }
    final im = _cropPendingImage!;
    setState(() {
      _cropPendingImage = null;
      _tool = Tool.pen;
    });
    // 选区夹到「当前显示的那一块」内，圈到图片外时按边界算
    final l = math.max(minX, im.x);
    final t = math.max(minY, im.y);
    final r = math.min(maxX, im.x + im.w);
    final b = math.min(maxY, im.y + im.h);
    if (r - l < 1 || b - t < 1) return; // 退化成一条线/一个点，不裁
    final full = _fullScreenRect(im);
    if (full.width <= 0 || full.height <= 0) return;
    // 选区是在屏幕上圈的，要换算回「源图」的归一化坐标；
    // 图片若已裁过一次，显示区只是源图的一部分，不换算就会取错区域
    // （圈的是左边、裁出来是右边的另一块）。
    _updateImageCrop(
      im.copyWith(x: l, y: t, w: r - l, h: b - t),
      {
        'sx': ((l - full.left) / full.width).clamp(0.0, 1.0),
        'sy': ((t - full.top) / full.height).clamp(0.0, 1.0),
        'sw': ((r - l) / full.width).clamp(0.0, 1.0),
        'sh': ((b - t) / full.height).clamp(0.0, 1.0),
      },
    );
  }

  // ---------- 音频录制 / 回放 ----------
  Future<void> _toggleRecord() async {
    if (_recording) {
      await _recorder.stop();
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/notes/${_note!.id}');
      final path = '${dir.path}/audio.m4a';
      if (!mounted) return; // 停止录音期间用户已退出编辑器
      setState(() {
        _recording = false;
        _note = _note!.copyWith(
          audioPath: path,
          audioStart: _recBase != null ? _recBase! ~/ 1000 : null,
        );
      });
      await _save();
      _toast('录音已停止');
    } else {
      final perm = await _recorder.hasPermission();
      if (perm != true) {
        _toast('无麦克风权限');
        return;
      }
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/notes/${_note!.id}');
      await dir.create(recursive: true);
      await _recorder.start(path: '${dir.path}/audio.m4a');
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recBase = DateTime.now().microsecondsSinceEpoch;
      });
      _toast('录音中…再次点击停止');
    }
  }

  void _playback() {
    if (_note!.audioPath == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlaybackPage(_note!)));
  }

  @override
  Widget build(BuildContext context) {
    if (_note == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final page = _cur;
    final wide = MediaQuery.of(context).size.width >= 720; // 平板/横屏：全部工具内联；手机：主操作内联 + 次操作收进菜单
    final left = AppSettings.instance.leftHand;
    final effColor = _tool == Tool.laser ? Colors.red : _color;
    final effSize = _tool == Tool.laser ? 6.0 : _size;
    return Scaffold(
      appBar: AppBar(
        title: Text(_note!.title),
        actions: _appBarActions(wide),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _readingMode == 0
                ? Row(
                    children: [
                      if (!left) _rail(wide ? 58 : 52),
                      Expanded(
                        child: Column(
                          children: [
                            _propertyPanel(),
                            Expanded(
                              // 双指缩放 + 拖动平移统一交给 InteractiveViewer：
                              // scaleEnabled 常开（书写中也能捏合缩放）；
                              // panEnabled 仅在「拖动模式」开启 —— 这就是「写的时候不要乱动」。
                              child: InteractiveViewer(
                                transformationController: _viewer,
                                scaleEnabled: true,
                                panEnabled: _panMode,
                                // 画布尺寸就是页面尺寸，不能被压成视口大小
                                constrained: false,
                                minScale: 0.4,
                                maxScale: 6.0,
                                boundaryMargin: const EdgeInsets.all(400),
                                child: FadeTransition(
                                  opacity: CurvedAnimation(
                                    parent: _flipCtrl,
                                    curve: Curves.easeIn,
                                  ),
                                  child: Builder(
                                        builder: (ctx) {
                                          final rot = (page.rotation / 90).round();
                                          final swap = rot % 2 == 1;
                                          final cw = swap ? page.height : page.width;
                                          final ch = swap ? page.width : page.height;
                                          return SizedBox(
                                            width: cw,
                                            height: ch,
                                            child: HandwritingCanvas(
                                              strokes: page.strokes,
                                              bgPath: page.bgPath,
                                              template: page.template,
                                              rotation: page.rotation,
                                              paperColor: page.paperColor,
                                              eraserMode: _eraserMode,
                                              highlighterFlat: _highlighterFlat,
                                              panMode: _panMode,
                                              rectLasso: _rectLasso,
                                              unbounded: page.unbounded,
                                              onImageUpdated: _updateImage,
                                              tool: _tool,
                                              onStrokesUpdated: _updateStrokes,
                                              color: effColor,
                                              size: effSize,
                                              pageW: page.width,
                                              pageH: page.height,
                                              layers: page.layers,
                                              textBoxes: page.textBoxes,
                                              images: page.images,
                                              usePressure:
                                                  AppSettings.instance.usePressure,
                                              onStrokeEnd: _commitStroke,
                                              onStrokeRemoved: _removeStroke,
                                              onUndo: _undoOp,
                                              onRedo: _redoOp,
                                              onTextBoxAdded: _upsertTextBox,
                                              onTextBoxUpdated: _upsertTextBox,
                                              onTextBoxRemoved: _removeTextBox,
                                              onImageAdded: (_) {},
                                              onImageRemoved: _removeImage,
                                              onLassoCompleted: _applyFreeCrop,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (left) _rail(wide ? 58 : 52),
                    ],
                  )
                : _buildReadingView(),
          ),
          // 悬浮笔盒：浮在画布之上，可拖动 / 收起；空白区域不拦截手写事件
          if (_readingMode == 0)
            FloatingPenBox(
              key: _penBoxKey,
              presets: _penBoxPresets,
              current: _currentBrush,
              onApply: _applyPreset,
              onSave: () => _savePreset(),
              onDelete: _deletePreset,
              onEdit: _openBrushEditorForPreset,
            ),
        ],
      ),
    );
  }
}

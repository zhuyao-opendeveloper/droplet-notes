import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:uuid/uuid.dart';

import '../models/point.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../models/page.dart';
import '../models/layer.dart' as layer;
import '../models/content.dart';
import '../engine/freehand.dart';
import '../engine/geometry.dart';
import '../engine/scene_cache.dart';
import '../engine/shape_recognizer.dart';
import '../theme.dart';

/// 手写画布：处理指针压感、实时预览、橡皮命中、套索选择变换；背景层 + 笔迹层分离。
class HandwritingCanvas extends StatefulWidget {
  final List<Stroke> strokes;
  final String? bgPath;
  final Tool tool;
  final Color color;
  final double size;
  final double pageW;
  final double pageH;
  final PageTemplate template;
  final List<layer.Layer> layers;
  final double rotation; // 页面旋转角度（0/90/180/270）
  final bool interactive; // 缩略图/阅读模式用 false（只读）
  final List<TextBox> textBoxes;
  final List<NoteImage> images;
  final int? paperColor; // 纸张底色（ARGB int，null=白/护眼）
  final int eraserMode; // 0 整笔擦除 / 1 区域(像素)擦除 / 2 只擦荧光笔
  final bool highlighterFlat; // 荧光笔平头（关闭圆角端点）
  /// 拖动模式：单指平移页面（平移由外层 InteractiveViewer 承担），画布不落笔。
  final bool panMode;
  /// 套索用矩形框选（true=拖出一个矩形选区；false=传统自由圈选）。
  final bool rectLasso;
  /// 无边画布：允许写到页面边界之外（父级据此自动扩展页面尺寸）。
  final bool unbounded;
  /// 图片被移动 / 缩放后的回写（NULL=只读场景，如缩略图）。
  final void Function(NoteImage)? onImageUpdated;
  final void Function(Stroke stroke) onStrokeEnd;
  final void Function(TextBox) onTextBoxAdded;
  final void Function(TextBox) onTextBoxUpdated;
  final void Function(String id) onTextBoxRemoved;
  final void Function(NoteImage) onImageAdded;
  final void Function(String id) onImageRemoved;
  final void Function(Stroke removed) onStrokeRemoved;
  final void Function(List<Stroke> updated) onStrokesUpdated;
  final void Function(List<Offset> polygon)? onLassoCompleted; // 套索完成（自由裁剪）
  final VoidCallback? onUndo; // 双指撤销
  final VoidCallback? onRedo; // 三指重做
  final bool usePressure; // 压感笔迹开关

  const HandwritingCanvas({
    super.key,
    required this.strokes,
    this.bgPath,
    required this.tool,
    required this.color,
    required this.size,
    required this.pageW,
    required this.pageH,
    this.template = PageTemplate.none,
    this.layers = const [layer.Layer(id: layer.Layer.defaultId, name: '内容')],
    this.rotation = 0.0,
    this.interactive = true,
    this.textBoxes = const [],
    this.images = const [],
    this.paperColor,
    this.eraserMode = 0,
    this.highlighterFlat = false,
    this.panMode = false,
    this.rectLasso = false,
    this.unbounded = false,
    this.onImageUpdated,
    required this.onStrokeEnd,
    required this.onTextBoxAdded,
    required this.onTextBoxUpdated,
    required this.onTextBoxRemoved,
    required this.onImageAdded,
    required this.onImageRemoved,
    required this.onStrokeRemoved,
    required this.onStrokesUpdated,
    this.onLassoCompleted,
    this.onUndo,
    this.onRedo,
    this.usePressure = true,
  });

  @override
  State<HandwritingCanvas> createState() => _HandwritingCanvasState();
}

enum _Handle { none, move, scaleTL, scaleTR, scaleBL, scaleBR, rotate, delete }

/// 图片 / 文本框的手柄拖拽类型。
enum _ObjDrag { none, move, resizeBR }

/// 套索选中态底部色板（改色用）。白放最后，方便在深色背景上辨认。
const List<Color> _lassoSwatches = [
  Colors.black,
  Colors.red,
  Colors.orange,
  Colors.amber,
  Colors.green,
  Colors.blue,
  Colors.purple,
  Colors.white,
];

/// 在选区包围盒 [b] 下方排一行色板，返回各色块矩形（绘制与命中复用同一布局）。
List<Rect> _swatchRectsFor(Rect b) {
  const double sw = 22, gap = 4;
  final double y = b.bottom + 12;
  final rects = <Rect>[];
  for (var i = 0; i < _lassoSwatches.length; i++) {
    rects.add(Rect.fromLTWH(b.left + i * (sw + gap), y, sw, sw));
  }
  return rects;
}

class _HandwritingCanvasState extends State<HandwritingCanvas> {
  List<Point> _current = [];
  ui.Image? _bg;
  // 不能用 final：图片解码完成后整个 map 会被整体替换
  Map<String, ui.Image> _imgMap = {};
  /// 静态场景（底图+模板+图片+文本框+已提交笔迹）缓存，避免每帧全量重绘
  final SceneCache _scene = SceneCache();
  List<Offset> _lasso = [];
  List<Stroke> _selected = [];
  Offset _selOffset = Offset.zero;
  double _selScale = 1.0;
  double _selRot = 0.0;
  _Handle _drag = _Handle.none;
  Offset _dragStart = Offset.zero;
  Offset _selStartOffset = Offset.zero;
  double _selStartScale = 1.0;
  double _selStartRot = 0.0;
  Rect _boundsStart = Rect.zero;
  final Set<int> _pointers = {}; // 多点触控计数（双指撤销/三指重做）
  final Map<int, ui.PointerDeviceKind> _pointerKinds = {}; // 指针类型，区分触控笔 / 手指触摸
  bool _gestureActive = false; // 多指手势进行中（期间不绘制，全抬起后丢弃误触）
  RecognizedShape? _snap; // 已吸附的规整形状（非 null = 当前笔画处于吸附态，预览用规整几何）
  Timer? _holdTimer; // 按住吸附计时器（shapeToolRequireHoldToSnap）
  Offset _lastMove = Offset.zero; // 上一次采样点，用于判断吸附后是否继续移动
  // 吸附态「拖动修改」的节流基准：手指每移动一段距离且间隔够久才重跑一次识别，
  // 否则每个 move 事件都跑一遍会让长笔画越拖越卡。
  Offset _snapLastAt = Offset.zero;
  DateTime _snapLastTime = DateTime.now();

  // ---- 多指手势：区分「多指轻点(撤销/重做)」与「捏合缩放/平移」----
  final Map<int, Offset> _ptrPos = {};
  int _multiPeak = 1; // 本次手势同时按下的最大指针数
  double _multiTravel = 0; // 手势期间累计位移：大=拖拽/缩放，小=轻点
  DateTime? _multiStart;

  // ---- 矩形套索（方框选择）----
  Offset? _rectStart;
  Offset? _rectEnd;

  // ---- 图片 / 文本框 选中：移动 + 缩放 ----
  String? _selObjId;
  bool _selObjIsImage = false;
  _ObjDrag _objDrag = _ObjDrag.none;
  Rect _objStartRect = Rect.zero;
  /// 缩放开始时的字号。
  ///
  /// 必须记录起始值：缩放按「相对拖拽起点的比例」逐帧回写，若直接用实时
  /// tb.fontSize 乘比例，每帧都会在上一次结果上再乘一遍 —— 一次拖拽内字号
  /// 指数级膨胀（16→24→36→54… 直到撞 clamp 上限）。宽高用的是 _objStartRect
  /// 的绝对值所以正确，字号必须同样以起始值为基准。
  double _objStartFontSize = 16.0;

  /// 手绘图形识别是否可用：开启识别 + 当前是书写笔（形状工具本身已规整，无需识别）
  bool get _recogEnabled =>
      AppSettings.instance.shapeRecognition &&
      widget.tool.isPenLike &&
      !widget.tool.isLaser; // 激光笔不落笔，不参与识别

  /// 对当前笔画做一次「识别 + 美化」。
  ///
  /// 只认 **直线 / 圆 / 曲线** 三类（see [ShapeRecognizer.beautifySimple]）：
  /// curve 也会被返回，但内容是**平滑去噪**后的曲线，不是原始手绘点。
  RecognizedShape? _tryRecognize(List<Point> pts) {
    if (!_recogEnabled || pts.length < 8) return null;
    return ShapeRecognizer.beautifySimple(
      pts,
      tolerance: AppSettings.instance.shapeTolerance,
    );
  }

  /// 长按吸附：**不提笔**停留 _holdMs 才触发识别（唯一触发路径）。
  ///
  /// 抬笔时不再兜底识别 —— 之前抬笔无条件再识别一次，于是随手写个字
  /// 也会被拉成某个形状，这是"写什么都乱识别"的根因。
  void _scheduleHoldSnap() {
    _holdTimer?.cancel();
    if (!_recogEnabled) return;
    if (_snap != null) return; // 已吸附，交给 _onMove 持续调整
    _holdTimer = Timer(const Duration(milliseconds: 520), () {
      if (!mounted || _current.isEmpty) return;
      final r = _tryRecognize(_current);
      if (r == null) return;
      _snapLastAt = Offset.zero; // 进入吸附态，重置调整节流基准
      _snapLastTime = DateTime.now();
      setState(() => _snap = r);
    });
  }

  void _clearSnap() {
    _holdTimer?.cancel();
    _snap = null;
  }

  /// 形状是否退化到画不出来（手指轻点一下 / 拖出零面积）。
  ///
  /// 阈值 3px：比这更小的图形肉眼根本看不见，却会实打实占一条撤销记录。
  bool _isDegenerate(List<Point> pts) {
    if (pts.length < 2) return true;
    var minX = pts[0].x, maxX = pts[0].x;
    var minY = pts[0].y, maxY = pts[0].y;
    for (final p in pts) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    return (maxX - minX) < 3 && (maxY - minY) < 3;
  }

  /// 当前是否有触控笔（含反向笔）按下——用于手掌防误触判断。
  bool get _stylusActive =>
      _pointerKinds.containsValue(ui.PointerDeviceKind.stylus) ||
      _pointerKinds.containsValue(ui.PointerDeviceKind.invertedStylus);

  /// 取本点压感：只在「压感开关开启 + 真实触控笔」时用原始压感并夹到 [0.05,1]，
  /// 其余（手指触摸 / 鼠标 / 关闭压感）一律返回 0.5 恒定值。
  /// 这样非压感设备得到均匀笔宽，不会再出现随书写速度忽粗忽细的不可用现象。
  double _pressFor(PointerEvent e) {
    if (!widget.usePressure) return 0.5;
    final k = e.kind;
    if (k == ui.PointerDeviceKind.stylus || k == ui.PointerDeviceKind.invertedStylus) {
      final pr = e.pressure;
      if (pr.isFinite && pr > 0) return pr.clamp(0.05, 1.0);
    }
    return 0.5;
  }
  Timer? _laserTimer; // 激光笔拖尾淡出计时器

  @override
  void initState() {
    super.initState();
    _loadBg();
    _loadImages();
  }

  @override
  void dispose() {
    _laserTimer?.cancel();
    _holdTimer?.cancel();
    _scene.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HandwritingCanvas old) {
    super.didUpdateWidget(old);
    // 静态场景的输入项只要有一项变了，缓存就必须失效。
    // 注意：书写过程中的 setState 只改 _current / _lasso / 选中变换，不会走到这里，
    // 所以书写时缓存保持有效 —— 这正是性能优化的关键。
    if (old.strokes != widget.strokes ||
        old.layers != widget.layers ||
        old.textBoxes != widget.textBoxes ||
        old.images != widget.images ||
        old.bgPath != widget.bgPath ||
        old.template != widget.template ||
        old.paperColor != widget.paperColor ||
        old.pageW != widget.pageW ||
        old.pageH != widget.pageH) {
      _scene.invalidate();
    }
    if (old.bgPath != widget.bgPath) _loadBg();
    if (old.images != widget.images) _loadImages();
    if (old.tool.isLasso && !widget.tool.isLasso) {
      _selected = [];
      _resetTransform();
    }
    if (old.strokes != widget.strokes) {
      final ids = {for (final s in widget.strokes) s.id};
      if (_selected.any((s) => !ids.contains(s.id))) {
        _selected = _selected.where((s) => ids.contains(s.id)).toList();
        _resetTransform();
      }
    }
  }

  void _resetTransform() {
    _selOffset = Offset.zero;
    _selScale = 1.0;
    _selRot = 0.0;
  }

  Future<void> _loadBg() async {
    if (widget.bgPath == null) {
      if (_bg != null) {
        _scene.invalidate();
        setState(() => _bg = null);
      }
      return;
    }
    try {
      final data = await File(widget.bgPath!).readAsBytes();
      // PDF 底图同样降采样：大尺寸扫描页按原始分辨率解码会卡死（8MB 文件场景）。
      // 目标 = 页面尺寸 × 2（缩放时仍清晰），上限 2400。
      const maxSide = 2400.0;
      final tw = (widget.pageW * 2).clamp(1.0, maxSide).round();
      final th = (widget.pageH * 2).clamp(1.0, maxSide).round();
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: tw,
        targetHeight: th,
      );
      final fi = await codec.getNextFrame();
      // 图片是异步解码的，不会触发 didUpdateWidget，必须显式让场景缓存失效
      _scene.invalidate();
      if (!mounted) return; // 解码耗时期间组件可能已被销毁
      setState(() => _bg = fi.image);
    } catch (_) {}
  }

  Future<void> _loadImages() async {
    final map = <String, ui.Image>{};
    for (final im in widget.images) {
      try {
        final data = await File(im.path).readAsBytes();
        // 大图性能：按「显示尺寸」降采样解码。
        // 8MB 的原图若按原始分辨率解码，会瞬间吃掉几百 MB 内存并卡死 UI。
        // 目标取显示宽高的 2 倍（保证缩放时够清晰），上限 2000 防止超大图爆内存。
        const maxSide = 2000.0;
        final tw = (im.w * 2).clamp(1.0, maxSide).round();
        final th = (im.h * 2).clamp(1.0, maxSide).round();
        final codec = await ui.instantiateImageCodec(
          data,
          targetWidth: tw,
          targetHeight: th,
        );
        final fi = await codec.getNextFrame();
        map[im.id] = fi.image;
      } catch (_) {}
    }
    // 同为异步解码，显式失效
    _scene.invalidate();
    if (mounted) setState(() => _imgMap = map);
  }

  /// 选中内容的包围盒。复用 Geometry 的 AABB 缓存 ——
  /// 该 getter 在拖拽/命中等每帧路径上被多次访问，原先每次都全点重算。
  Rect get _selBounds => Geometry.aabbOfStrokes(_selected);

  Offset _transformPoint(Offset p, Rect c, Offset d, double scale, double rot) {
    var v = p - c.center;
    if (rot != 0) {
      final cos = math.cos(rot), sin = math.sin(rot);
      v = Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos);
    }
    return v * scale + c.center + d;
  }

  Stroke _transformStroke(Stroke s, Rect c, Offset d, double scale, double rot) {
    // rect / ellipse 的 2 点形式是「包围盒对角」，隐含轴对齐前提，旋转下无法表达：
    //  - 矩形转 30°：按新两点画另一个轴对齐矩形，面积 30000 -> 17280
    //  - 正圆转 45°：对角点转成水平相对，包围盒高度塌成 0，圆直接消失
    //  - 椭圆转 30°：半轴 (100,50) -> (93.3, 61.6)
    // 旋转前先用 Freehand.expandForRotation 展开成显式轮廓（矩形 4 角 / 椭圆 36 点），
    // 逐点变换后形状保持不变。未旋转时保持 2 点紧凑形式，便于继续编辑。
    final src = rot != 0 ? Freehand.expandForRotation(s.tool, s.points) : s.points;
    final points = src.map((p) {
      final np = _transformPoint(Offset(p.x, p.y), c, d, scale, rot);
      return Point(np.dx, np.dy, p.pressure);
    }).toList();
    return Stroke(
      id: s.id,
      tool: s.tool,
      color: s.color,
      size: s.size * scale,
      points: points,
      layerId: s.layerId,
      opacity: s.opacity,
    );
  }

  List<Stroke> _transformedSelected() =>
      _selected.map((s) => _transformStroke(s, _selBounds, _selOffset, _selScale, _selRot)).toList();

  /// 命中底部色板的色块索引（-1 = 未命中）。复用与绘制相同的布局。
  int _swatchIndex(Offset p) {
    final b = _selBounds.inflate(4);
    final rects = _swatchRectsFor(b);
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].contains(p)) return i;
    }
    return -1;
  }

  /// 套索选中后改色：重建选中笔迹（同 id、改 color）并上报，保留变换状态。
  void _recolorSelected(int idx) {
    final c = _lassoSwatches[idx].value;
    final recolored = _selected
        .map((s) => Stroke(
              id: s.id,
              tool: s.tool,
              color: c,
              size: s.size,
              points: s.points,
              layerId: s.layerId,
              opacity: s.opacity,
              t: s.t,
              meta: s.meta,
            ))
        .toList();
    _selected = recolored;
    widget.onStrokesUpdated(recolored);
    setState(() {});
  }

  /// 形状工具实时吸附（仅对直接形状工具生效，不影响手绘识别）：
  /// - angleCorrection：line/arrow 吸附到最近 15°；
  /// - rulerAngle≠0：line/arrow 锁定到该角度（优先于角度矫正）；
  /// - shapeAlignment：rect/ellipse/triangle 包围盒对齐页面中线（阈值 14px）。
  void _applyShapeSnapping() {
    if (_current.length < 2) return;
    final s = AppSettings.instance;
    if (!s.angleCorrection && s.rulerAngle == 0 && !s.shapeAlignment) return;
    final a = _current.first;
    final last = _current.last;
    var bx = last.x, by = last.y;
    if (widget.tool == Tool.line || widget.tool == Tool.arrow) {
      var ang = math.atan2(by - a.y, bx - a.x);
      if (s.rulerAngle != 0) {
        ang = s.rulerAngle * math.pi / 180;
      } else if (s.angleCorrection) {
        const step = 15 * math.pi / 180;
        ang = (ang / step).round() * step;
      }
      final len = math.sqrt((bx - a.x) * (bx - a.x) + (by - a.y) * (by - a.y));
      bx = a.x + len * math.cos(ang);
      by = a.y + len * math.sin(ang);
    }
    if (s.shapeAlignment &&
        (widget.tool == Tool.rect ||
            widget.tool == Tool.ellipse ||
            widget.tool == Tool.triangle)) {
      final cx = (a.x + bx) / 2, cy = (a.y + by) / 2;
      const thr = 14.0;
      final pcx = widget.pageW / 2, pcy = widget.pageH / 2;
      if ((cx - pcx).abs() < thr) bx += pcx - cx;
      if ((cy - pcy).abs() < thr) by += pcy - cy;
    }
    if (bx != last.x || by != last.y) {
      _current[_current.length - 1] = Point(bx, by, last.pressure);
    }
  }

  // 几何运算（AABB 缓存 / 点到线段距离 / 多边形相交）统一见 lib/engine/geometry.dart

  _Handle _hitHandle(Offset p) {
    final b = _selBounds;
    if (b == Rect.zero) return _Handle.none;
    final c = b.center;
    final map = {
      _Handle.scaleTL: b.topLeft,
      _Handle.scaleTR: b.topRight,
      _Handle.scaleBL: b.bottomLeft,
      _Handle.scaleBR: b.bottomRight,
      _Handle.rotate: Offset(c.dx, b.top - 28),
      _Handle.delete: b.topRight + const Offset(22, -22),
    };
    for (final e in map.entries) {
      if ((e.value - p).distance < 18) return e.key;
    }
    return _Handle.none;
  }

  /// 当前选中的图片 / 文本框矩形（null=未选中，或对象已被删除）。
  Rect? _selObjRect() {
    final id = _selObjId;
    if (id == null) return null;
    if (_selObjIsImage) {
      for (final im in widget.images) {
        if (im.id == id) return Rect.fromLTWH(im.x, im.y, im.w, im.h);
      }
    } else {
      for (final tb in widget.textBoxes) {
        if (tb.id == id) return Rect.fromLTWH(tb.x, tb.y, tb.w, tb.h);
      }
    }
    return null;
  }

  /// 命中图片或文本框（后加入的在上层 → 逆序优先）。
  ({String id, bool isImage, Rect rect})? _hitObject(Offset p) {
    for (final im in widget.images.reversed) {
      final r = Rect.fromLTWH(im.x, im.y, im.w, im.h);
      if (r.contains(p)) return (id: im.id, isImage: true, rect: r);
    }
    for (final tb in widget.textBoxes.reversed) {
      final r = Rect.fromLTWH(tb.x, tb.y, tb.w, tb.h);
      if (r.contains(p)) return (id: tb.id, isImage: false, rect: r);
    }
    return null;
  }

  /// 对象右下角的缩放手柄热区。
  Rect _objResizeHandle(Rect r) =>
      Rect.fromLTWH(r.right - 14, r.bottom - 14, 28, 28);

  /// 取文本框当前字号（图片无字号，返回兜底值）。
  double _fontSizeOf(String? id) {
    if (id == null) return 16.0;
    for (final tb in widget.textBoxes) {
      if (tb.id == id) return tb.fontSize;
    }
    return 16.0;
  }

  void _onDown(PointerDownEvent e) {
    final p = e.localPosition;
    _pointerKinds[e.pointer] = e.kind;
    // 手掌防误触：有触控笔按下时忽略手指触摸（避免手掌误画，也不触发多指手势）
    if (AppSettings.instance.palmReject &&
        e.kind == ui.PointerDeviceKind.touch &&
        _stylusActive) {
      return;
    }
    _pointers.add(e.pointer);
    _ptrPos[e.pointer] = p;
    if (_pointers.length > 1) {
      // 多指按下：立刻取消当前笔画（避免误画出线）。
      // 但【不再立刻撤销/重做】—— 改为「多指轻点」判定（见 _onUp），
      // 这样双指捏合能正常缩放（缩放在外层 InteractiveViewer 里处理）。
      if (_multiStart == null) {
        _multiStart = DateTime.now();
        _multiTravel = 0;
        _multiPeak = _pointers.length;
      }
      _multiPeak = math.max(_multiPeak, _pointers.length);
      _current = [];
      _clearSnap();
      _gestureActive = true;
      setState(() {});
      return;
    }
    if (_gestureActive) return; // 手势残留，忽略本次单指

    // 拖动模式：单指平移页面（平移由外层 InteractiveViewer 承担），画布不落笔。
    if (widget.panMode) return;
    if (widget.tool == Tool.eraser) {
      _eraseAt(p);
      return;
    }
    if (widget.tool.isLasso) {
      // A) 已选中的图片 / 文本框：缩放手柄 → 移动
      final obj = _selObjRect();
      if (obj != null) {
        if (_objResizeHandle(obj).contains(p)) {
          _objDrag = _ObjDrag.resizeBR;
          _objStartRect = obj;
          _objStartFontSize = _fontSizeOf(_selObjId);
          _dragStart = p;
          setState(() {});
          return;
        }
        if (obj.inflate(8).contains(p)) {
          _objDrag = _ObjDrag.move;
          _objStartRect = obj;
          _dragStart = p;
          setState(() {});
          return;
        }
      }
      // B) 命中图片 / 文本框 → 选中（Notein：套索可筛选图片与文本框）
      final hit = _hitObject(p);
      if (hit != null) {
        _selObjId = hit.id;
        _selObjIsImage = hit.isImage;
        _objDrag = _ObjDrag.move;
        _objStartRect = hit.rect;
        _dragStart = p;
        _selected = [];
        _resetTransform();
        setState(() {});
        return;
      }
      _selObjId = null; // 点空白处：取消对象选中

      // C) 笔迹选中态：删除 / 改色 / 手柄 / 整体移动
      if (_selected.isNotEmpty) {
        final h = _hitHandle(p);
        if (h == _Handle.delete) {
          for (final s in _selected) widget.onStrokeRemoved(s);
          _selected = [];
          _resetTransform();
          setState(() {});
          return;
        }
        final si = _swatchIndex(p);
        if (si >= 0) {
          _recolorSelected(si);
          return;
        }
        if (h != _Handle.none) {
          _drag = h;
          _dragStart = p;
          _selStartOffset = _selOffset;
          _selStartScale = _selScale;
          _selStartRot = _selRot;
          _boundsStart = _selBounds;
          setState(() {});
          return;
        }
        if (_selBounds.inflate(8).contains(p)) {
          _drag = _Handle.move;
          _dragStart = p;
          _selStartOffset = _selOffset;
          setState(() {});
          return;
        }
        _selected = [];
        _resetTransform();
      }
      // D) 开始新选区：矩形框选（方框选择）/ 自由圈选
      if (widget.rectLasso) {
        _rectStart = p;
        _rectEnd = p;
      } else {
        _lasso = [p];
      }
      setState(() {});
      return;
    }
    if (widget.tool.isText) {
      for (final tb in widget.textBoxes) {
        if (Rect.fromLTWH(tb.x, tb.y, tb.w, tb.h).contains(p)) {
          _editTextBox(tb, isNew: false);
          return;
        }
      }
      for (final im in widget.images) {
        if (Rect.fromLTWH(im.x, im.y, im.w, im.h).contains(p)) {
          _confirmDeleteImage(im);
          return;
        }
      }
      _editTextBox(
        TextBox(id: const Uuid().v4(), x: p.dx, y: p.dy),
        isNew: true,
      );
      return;
    }
    _current = [Point(p.dx, p.dy, _pressFor(e))];
    _lastMove = p;
    _clearSnap();
    setState(() {});
  }

  void _onMove(PointerMoveEvent e) {
    final p = e.localPosition;
    if (AppSettings.instance.palmReject &&
        e.kind == ui.PointerDeviceKind.touch &&
        _stylusActive) {
      return; // 手掌触摸，忽略
    }
    final prev = _ptrPos[e.pointer];
    _ptrPos[e.pointer] = p;
    if (_pointers.length > 1) {
      // 多指期间只累计位移：大位移=捏合/平移，小位移=轻点（供撤销判定）。
      // 缩放与平移由外层 InteractiveViewer 处理，这里不重绘，避免干扰。
      if (prev != null) _multiTravel += (p - prev).distance;
      return;
    }
    if (_gestureActive || _pointers.length != 1) return; // 多指手势期间不绘制
    if (widget.panMode) return; // 拖动模式：不落笔

    // 图片 / 文本框：移动 / 缩放（实时回写，父级重建后重绘）
    if (_objDrag != _ObjDrag.none && _selObjId != null) {
      final d = p - _dragStart;
      final id = _selObjId!;
      final baseW = _objStartRect.width > 0 ? _objStartRect.width : 1.0;
      final ratio = (_objStartRect.width + d.dx) / baseW;
      if (_selObjIsImage) {
        for (final im in widget.images) {
          if (im.id != id) continue;
          if (_objDrag == _ObjDrag.move) {
            widget.onImageUpdated?.call(im.copyWith(
              x: _objStartRect.left + d.dx,
              y: _objStartRect.top + d.dy,
            ));
          } else {
            // 等比缩放：按宽度比例同步高度，避免图片被拉变形
            widget.onImageUpdated?.call(im.copyWith(
              w: (_objStartRect.width + d.dx).clamp(24.0, 4000.0).toDouble(),
              h: (_objStartRect.height * ratio).clamp(24.0, 4000.0).toDouble(),
            ));
          }
          break;
        }
      } else {
        for (final tb in widget.textBoxes) {
          if (tb.id != id) continue;
          if (_objDrag == _ObjDrag.move) {
            widget.onTextBoxUpdated(tb.copyWith(
              x: _objStartRect.left + d.dx,
              y: _objStartRect.top + d.dy,
            ));
          } else {
            widget.onTextBoxUpdated(tb.copyWith(
              w: (_objStartRect.width + d.dx).clamp(40.0, 4000.0).toDouble(),
              h: (_objStartRect.height * ratio).clamp(24.0, 4000.0).toDouble(),
              // 以拖拽起始字号为基准（不能用实时 tb.fontSize，会逐帧累乘）
              fontSize: (_objStartFontSize * ratio).clamp(6.0, 200.0).toDouble(),
            ));
          }
          break;
        }
      }
      _scene.invalidate();
      setState(() {});
      return;
    }
    if (widget.tool == Tool.eraser) {
      _eraseAt(p);
      return;
    }
    if (widget.tool.isLasso) {
      if (_drag == _Handle.none) {
        if (_rectStart != null) {
          _rectEnd = p; // 矩形框选：更新对角点
          setState(() {});
          return;
        }
        if (_lasso.isNotEmpty) {
          _lasso.add(p);
          setState(() {});
        }
        return;
      }
      final c = _boundsStart.center;
      if (_drag == _Handle.move) {
        _selOffset = _selStartOffset + (p - _dragStart);
      } else if (_drag == _Handle.rotate) {
        _selRot = _selStartRot +
            (math.atan2(p.dy - c.dy, p.dx - c.dx) -
                math.atan2(_dragStart.dy - c.dy, _dragStart.dx - c.dx));
      } else {
        final d0 = (_dragStart - c).distance;
        final d1 = (p - c).distance;
        _selScale = _selStartScale * (d0 > 0 ? d1 / d0 : 1.0);
      }
      setState(() {});
      return;
    }
    if (_current.isEmpty) return;
    _lastMove = p;
    _current.add(Point(p.dx, p.dy, _pressFor(e)));
    if (widget.tool.isShape) _applyShapeSnapping();
    if (_snap != null) {
      // 吸附态：手指不提笔继续拖 = **调整形状**。把新点并进笔画再识别一次，
      // 形状就跟着手指走；抬笔时才最终落定（见 _onUp）。
      // 节流：距离 >10px 且距上次 >60ms 才重算，避免每帧全量识别拖垮帧率。
      final now = DateTime.now();
      if ((p - _snapLastAt).distance > 10 &&
          now.difference(_snapLastTime).inMilliseconds > 60) {
        final r = _tryRecognize(_current);
        if (r != null) _snap = r;
        _snapLastAt = p;
        _snapLastTime = now;
      }
    } else {
      _scheduleHoldSnap();
    }
    setState(() {});
  }

  double _cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

  bool _segIntersectsSeg(Offset a, Offset b, Offset c, Offset d) {
    final d1 = _cross(c, d, a), d2 = _cross(c, d, b);
    final d3 = _cross(a, b, c), d4 = _cross(a, b, d);
    return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
  }

  /// 线段 [a,b] 是否与矩形 r 相交（含端点落在矩形内）。
  bool _segIntersectsRect(Offset a, Offset b, Rect r) {
    if (r.contains(a) || r.contains(b)) return true;
    final corners = <Offset>[
      r.topLeft,
      r.topRight,
      r.bottomRight,
      r.bottomLeft,
    ];
    for (var i = 0; i < 4; i++) {
      if (_segIntersectsSeg(a, b, corners[i], corners[(i + 1) % 4])) {
        return true;
      }
    }
    return false;
  }

  void _onUp(PointerUpEvent e) {
    _pointerKinds.remove(e.pointer);
    if (AppSettings.instance.palmReject &&
        e.kind == ui.PointerDeviceKind.touch &&
        _stylusActive) {
      return; // 手掌触摸：未计入 _pointers，无需移除
    }
    _ptrPos.remove(e.pointer);
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) return; // 还有手指按着，等待全部抬起
    final wasGesture = _gestureActive;
    _gestureActive = false;
    if (wasGesture) {
      // 多指手势结束：用「位移 + 时长」区分轻点与捏合/拖拽。
      // 之前是第二根手指一按下就撤销，导致双指缩放完全没法用。
      final start = _multiStart;
      final dur = start == null
          ? 9999
          : DateTime.now().difference(start).inMilliseconds;
      final isTap = _multiTravel < 24 && dur < 350; // 位移小 + 时间短 = 轻点
      final peak = _multiPeak;
      _multiStart = null;
      _multiTravel = 0;
      _multiPeak = 1;
      _current = [];
      _clearSnap();
      if (isTap && peak == 2) {
        widget.onUndo?.call(); // 双指轻点：撤销
      } else if (isTap && peak == 3) {
        widget.onRedo?.call(); // 三指轻点：重做
      }
      setState(() {});
      return;
    }
    if (_objDrag != _ObjDrag.none) {
      _objDrag = _ObjDrag.none; // 对象移动/缩放已在 _onMove 实时回写，这里收尾
      setState(() {});
      return;
    }
    final p = e.localPosition;
    if (widget.tool == Tool.eraser) {
      _current = [];
      setState(() {});
      return;
    }
    if (widget.tool.isLasso) {
      if (_drag != _Handle.none) {
        final updated = _selected
            .map((s) => _transformStroke(s, _boundsStart, _selOffset, _selScale, _selRot))
            .toList();
        _selected = updated;
        _resetTransform();
        widget.onStrokesUpdated(updated);
        _drag = _Handle.none;
        setState(() {});
        return;
      }
      // 矩形框选（方框选择）：落定后按「部分落在框内即选中」取笔画
      if (_rectStart != null && _rectEnd != null) {
        final r = Rect.fromPoints(_rectStart!, _rectEnd!);
        if (r.width > 4 || r.height > 4) {
          final hits = <Stroke>[];
          for (final s in _interactive(_hiddenLayers)) {
            if (!Geometry.boundsOf(s).overlaps(r)) continue; // AABB 粗筛
            // 形状走真实轮廓：否则 2 点矩形/椭圆只有一条对角线参与判定，
            // 框选框住矩形的边（不含端点、不与对角线相交）会漏选。
            final poly = Geometry.hitPoints(s);
            final m = poly.length;
            // 闭合形状补上「末点→首点」的闭合边
            final segs = Geometry.isClosedShape(s) ? m : m - 1;
            var hit = false;
            for (var i = 0; i < m; i++) {
              if (r.contains(poly[i])) {
                hit = true;
                break;
              }
            }
            if (!hit) {
              for (var i = 0; i < segs; i++) {
                // 采样稀疏时「只判采样点」会漏选，必须连线段一起判
                if (_segIntersectsRect(poly[i], poly[(i + 1) % m], r)) {
                  hit = true;
                  break;
                }
              }
            }
            if (hit) hits.add(s);
          }
          _selected = hits;
          _resetTransform();
        }
        _rectStart = null;
        _rectEnd = null;
        setState(() {});
        return;
      }
      if (_lasso.length > 2) {
        final poly = List<Offset>.from(_lasso);
        final lassoAabb = Geometry.aabbOfOffsets(poly);
        final hits = <Stroke>[];
        for (final s in _interactive(_hiddenLayers)) {
          // AABB 粗筛（O(1) 排除绝大多数）+ 多边形精判。
          // 旧实现只判断「AABB 中心是否在多边形内」，长笔画被部分圈住时中心在圈外 → 漏选。
          if (!Geometry.boundsOf(s).overlaps(lassoAabb)) continue;
          if (Geometry.strokeIntersectsPolygon(s, poly)) hits.add(s);
        }
        _selected = hits;
        _resetTransform();
        widget.onLassoCompleted?.call(poly);
      }
      _lasso = [];
      setState(() {});
      return;
    }
    if (_current.isEmpty) {
      setState(() {});
      return;
    }
    if (widget.tool.isLaser) {
      // 激光笔：不落笔，停留一小会儿后淡出（原 700ms 太短，激光感不足）
      _laserTimer?.cancel();
      _laserTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _current = []);
      });
      return;
    }
    // 形状落定：**只用长按产生的吸附结果**，抬笔不再兜底识别。
    //
    // 之前写成 `_snap ?? _tryRecognize(_current)` —— 抬笔时无条件再识别一次，
    // 于是随手写的字、随手画的草图全被拉成某个形状（"写什么都乱识别"）。
    // 现在的规则：画完不提笔、长按 0.5s 才识别；识别后手指可以继续拖动
    // 调整（_onMove 里持续重识别），抬笔即吸附落定。
    final snap = _snap;
    _clearSnap();
    // curve 表示「只是把粗糙手绘平滑了」，仍用原笔型绘制，不能转成 pen 之外的形状工具
    final isCurve = snap != null && snap.kind == ShapeKind.curve;
    final tool =
        (snap != null && !isCurve) ? Tool.fromShapeKind(snap.kind.name) : widget.tool;
    // 形状工具拖拽存的是原始采样点，必须规整成几何控制点，
    // 否则 _shapePath 取前几个点连出退化的小多边形（矩形/三角形画不出来）。
    // 识别器的 snap.points 已是规整控制点，不可二次规整。
    final pts = snap != null
        ? List<Point>.from(snap.points)
        : (widget.tool.isShape
            ? Freehand.regularizeShape(widget.tool, _current)
            : List<Point>.from(_current));
    // 退化形状直接丢弃：手指轻点一下（首尾几乎重合）会生成一个面积为 0 的
    // 矩形/椭圆 —— 屏幕上什么都看不见，撤销栈里却多了一条记录，
    // 用户得连按好几下撤销才回得到上一步，看起来就像"这工具坏了"。
    if (tool.isShape && _isDegenerate(pts)) {
      _current = [];
      setState(() {});
      return;
    }
    final stroke = Stroke(
      id: const Uuid().v4(),
      tool: tool,
      color: widget.color.value,
      size: widget.size,
      points: pts,
      // 荧光笔平头：把 cap=false 标记存进 meta，freehand 渲染时读取
      meta: tool == Tool.highlighter && widget.highlighterFlat
          ? {'flat': true}
          : null,
    );
    _current = [];
    widget.onStrokeEnd(stroke);
    setState(() {});
  }

  /// 被隐藏的图层 id（图层面板里关掉眼睛的那些）。
  Set<String> get _hiddenLayers => {
        for (final l in widget.layers)
          if (!l.visible) l.id
      };

  /// 参与交互（擦除 / 套索 / 框选）的笔迹：排除隐藏图层上的。
  ///
  /// 绘制端已经过滤了隐藏图层，但交互端此前没有 —— 图层一隐藏，
  /// 橡皮擦随手一划就把看不见的笔迹擦掉了：屏幕上毫无反馈，
  /// 用户却永久丢掉了一整层内容。套索同理：会选中看不见的笔迹，
  /// 一拖动它们的位置就莫名变了。导出侧（pdf/export、page_raster、ocr）
  /// 早就有过滤，这里补齐交互侧。
  List<Stroke> _interactive(Set<String> hidden) =>
      hidden.isEmpty ? widget.strokes : widget.strokes.where((s) => !hidden.contains(s.layerId)).toList();

  void _eraseAt(Offset p) {
    final thr = widget.size + 10;
    // 仅擦胶带：整笔/区域擦除只作用于胶带笔（与「只擦荧光笔」互斥作用于各自笔型）
    final tapeOnly = AppSettings.instance.eraseTapeOnly;
    final hidden = _hiddenLayers; // 循环内复用，避免每笔都重建一次集合
    if (widget.eraserMode == 2) {
      // 只擦荧光笔：命中的荧光笔笔画整笔删除，其余笔迹不受影响
      for (final s in _interactive(hidden)) {
        if (s.tool != Tool.highlighter) continue;
        if (Geometry.strokeHitsCircle(s, p, thr)) {
          widget.onStrokeRemoved(s);
          return;
        }
      }
      return;
    }
    if (widget.eraserMode == 1) {
      // 区域(像素)擦除：剔除被橡皮圆触及的采样点，并把剩下的点**按连续区间拆成多笔**。
      //
      // 为什么必须拆分（原实现的 bug）：perfect_freehand 把 points 当作一条连续折线
      // 生成轮廓，只筛点不拆分的话，缺口两端的点会被直接连起来 —— 开了曲线平滑时
      // 还会把它抹得更平。结果"擦出一个洞"在画面上只是笔画被拉直，洞根本不存在。
      // 按连续区间切成多笔、每段独立成形，洞才真的出现。
      //
      // 形状笔迹不参与筛点：rect 只有 2 个控制点、旋转椭圆是一圈轮廓采样点，
      // 筛掉中间几个点会把形状彻底毁掉（2 点矩形被筛掉 1 点后直接消失）。
      // 形状仍是矢量可编辑对象，命中即整笔删除（与 GoodNotes 一致）。
      //
      // 判定用「点到线段」距离，避免快速书写采样稀疏时两点之间的笔迹擦不掉。
      final out = <Stroke>[];
      var changed = false;
      for (final s in widget.strokes) {
        // 本分支是整表重建（out 里没有的笔迹等于被删除），
        // 隐藏图层的笔迹必须原样写回，否则一个「看不见」就把整层清空了。
        if (hidden.contains(s.layerId)) {
          out.add(s);
          continue;
        }
        if (tapeOnly && s.tool != Tool.tape) continue;
        if (s.isShape) {
          if (Geometry.strokeHitsCircle(s, p, thr)) changed = true; // 不写回 = 整笔删除
          continue;
        }
        final runs = <List<Point>>[];
        var run = <Point>[];
        for (var i = 0; i < s.points.length; i++) {
          if (Geometry.pointTouchedByCircle(s.points, i, p, thr)) {
            if (run.isNotEmpty) {
              runs.add(run);
              run = <Point>[];
            }
          } else {
            run.add(s.points[i]);
          }
        }
        if (run.isNotEmpty) runs.add(run);

        if (runs.isEmpty) {
          changed = true; // 整笔被擦光
          continue;
        }
        if (runs.length == 1 && runs.first.length == s.points.length) {
          out.add(s); // 未触及
          continue;
        }
        changed = true;
        // 第一段沿用原 id（保留外部引用），后续各段新建 id
        var first = true;
        for (final seg in runs) {
          if (seg.length < 2) continue; // 单点段画不出东西
          out.add(Stroke(
            id: first ? s.id : const Uuid().v4(),
            tool: s.tool,
            color: s.color,
            size: s.size,
            points: seg,
            layerId: s.layerId,
            opacity: s.opacity,
            t: s.t,
            meta: s.meta,
          ));
          first = false;
        }
      }
      if (changed) widget.onStrokesUpdated(out);
      return;
    }
    for (final s in _interactive(hidden)) {
      if (tapeOnly && s.tool != Tool.tape) continue;
      if (Geometry.strokeHitsCircle(s, p, thr)) {
        widget.onStrokeRemoved(s);
        return;
      }
    }
  }

  Future<void> _editTextBox(TextBox tb, {bool isNew = false}) async {
    final ctl = TextEditingController(text: tb.text);
    var color = tb.color;
    var size = tb.fontSize;
    int? bg = tb.bg;
    int? border = tb.border;
    var radius = tb.radius;
    var bold = tb.bold;
    var align = tb.align;
    final palette = [
      Colors.black,
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.amber
    ];
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(isNew ? '新建文本框' : '编辑文本框'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctl,
                  maxLines: null,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '输入文字'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  children: palette
                      .map((c) => GestureDetector(
                            onTap: () => setD(() => color = c.value),
                            child: Container(
                              margin: const EdgeInsets.all(4),
                              width: 32,
                              height: 32,
                              color: c,
                              decoration: color == c.value
                                  ? BoxDecoration(
                                      border: Border.all(color: Colors.blue, width: 2))
                                  : null,
                            ),
                          ))
                      .toList(),
                ),
                Row(children: [
                  const Text('大小'),
                  Expanded(
                    child: Slider(
                      value: size,
                      min: 8,
                      max: 48,
                      onChanged: (v) => setD(() => size = v),
                    ),
                  ),
                ]),
                Row(children: [
                  const Text('背景'),
                  GestureDetector(
                    onTap: () => setD(() => bg = bg == null ? 0xFFFFF59D : null),
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      width: 28,
                      height: 28,
                      color: bg == null ? Colors.grey.shade300 : Color(bg!),
                      child: bg == null
                          ? const Icon(Icons.block, size: 16)
                          : null,
                    ),
                  ),
                  const Text('边框'),
                  GestureDetector(
                    onTap: () => setD(() => border = border == null ? 0xFF000000 : null),
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      width: 28,
                      height: 28,
                      color: border == null ? Colors.grey.shade300 : Color(border!),
                      child: border == null
                          ? const Icon(Icons.block, size: 16)
                          : null,
                    ),
                  ),
                  const Text('粗体'),
                  Checkbox(
                    value: bold,
                    onChanged: (v) => setD(() => bold = v ?? false),
                  ),
                ]),
                Row(children: [
                  const Text('对齐'),
                  IconButton(
                    icon: const Icon(Icons.format_align_left),
                    color: align == 0 ? Colors.blue : null,
                    onPressed: () => setD(() => align = 0),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_align_center),
                    color: align == 1 ? Colors.blue : null,
                    onPressed: () => setD(() => align = 1),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_align_right),
                    color: align == 2 ? Colors.blue : null,
                    onPressed: () => setD(() => align = 2),
                  ),
                ]),
                Row(children: [
                  const Text('圆角'),
                  Expanded(
                    child: Slider(
                      value: radius,
                      min: 0,
                      max: 24,
                      onChanged: (v) => setD(() => radius = v),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          actions: [
            if (!isNew)
              TextButton(
                onPressed: () {
                  widget.onTextBoxRemoved(tb.id);
                  Navigator.pop(ctx, false);
                },
                child: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      final updated = tb.copyWith(
        text: ctl.text,
        color: color,
        fontSize: size,
        bg: bg,
        border: border,
        radius: radius,
        bold: bold,
        align: align,
      );
      if (isNew) {
        widget.onTextBoxAdded(updated);
      } else {
        widget.onTextBoxUpdated(updated);
      }
    }
  }

  Future<void> _confirmDeleteImage(NoteImage im) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除图片？'),
        content: const Text('确定要删除此图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) widget.onImageRemoved(im.id);
  }

  @override
  Widget build(BuildContext context) {
    final selIds = {for (final s in _selected) s.id};
    final base = widget.strokes.where((s) => !selIds.contains(s.id)).toList();
    final transformed = widget.tool.isLasso ? _transformedSelected() : <Stroke>[];
    Widget content = CustomPaint(
      size: Size(widget.pageW, widget.pageH),
      isComplex: true,
        painter: _CanvasPainter(
          base,
          _snap?.points ?? _current,
          widget.tool,
          widget.color,
          widget.size,
          _bg,
          widget.pageW,
          widget.pageH,
          widget.template,
          transformed,
          _lasso,
          widget.layers,
          widget.textBoxes,
          widget.images,
          _imgMap,
          widget.paperColor,
          widget.interactive,
          // 吸附态：预览用规整几何 + 对应形状工具绘制。
          // curve 只是平滑过的手绘，仍按当前笔型画，不能套形状工具。
          currentTool: (_snap != null && _snap!.kind != ShapeKind.curve)
              ? Tool.fromShapeKind(_snap!.kind.name)
              : null,
          scene: _scene,
          selRect: (_rectStart == null || _rectEnd == null)
              ? null
              : Rect.fromPoints(_rectStart!, _rectEnd!),
          selObjId: _selObjId,
          selObjIsImage: _selObjIsImage,
        ),
    );
    if (widget.interactive) {
      content = Listener(
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        child: content,
      );
    }
    if (widget.rotation != 0) {
      content = RotatedBox(
        quarterTurns: (widget.rotation / 90).round(),
        child: content,
      );
    }
    return content;
  }
}

class _CanvasPainter extends CustomPainter {
  final List<Stroke> strokes;
  final List<Point> current;
  final Tool tool;
  final Color color;
  final double size;
  final ui.Image? bg;
  final double w;
  final double h;
  final PageTemplate template;
  final List<Stroke> selected;
  final List<Offset> lasso;
  final List<layer.Layer> layers;
  final List<TextBox> textBoxes;
  final List<NoteImage> images;
  final Map<String, ui.Image> imgMap;
  final int? paperColor;
  final bool interactive;
  /// 当前笔画的绘制工具覆盖（吸附预览时用形状工具，null = 用 [tool]）。
  final Tool? currentTool;
  /// 静态场景缓存（底图+模板+图片+文本框+已提交笔迹），跨帧复用。
  final SceneCache scene;
  /// 矩形框选（方框选择）进行中的预览矩形，null=未框选。
  final Rect? selRect;
  /// 当前选中的图片 / 文本框 id（绘制移动/缩放手柄用），null=未选中。
  final String? selObjId;
  final bool selObjIsImage;

  const _CanvasPainter(this.strokes, this.current, this.tool, this.color, this.size,
      this.bg, this.w, this.h, this.template, this.selected, this.lasso, this.layers,
      this.textBoxes, this.images, this.imgMap, this.paperColor, this.interactive,
      {this.currentTool, required this.scene, this.selRect, this.selObjId,
       this.selObjIsImage = false});

  bool get _eye => AppSettings.instance.themeMode == AppThemeMode.eyeCare;

  /// 当前活动笔画的预览点集。
  ///
  /// 形状工具拖拽时 [current] 是原始采样点，必须经
  /// [Freehand.regularizeShape] 收敛成几何控制点，否则 [_shapePath]
  /// 取前几个点连出退化多边形，用户拖拽过程中根本看不到形状。
  /// 吸附态（[currentTool] 非 null）的点已由识别器规整好，不可二次规整。
  List<Point> _previewPoints() {
    final t = currentTool ?? tool;
    if (currentTool == null && t.isShape) {
      // 形状工具：不做跟手预测。predict 会在末尾追加外推点，
      // 会让矩形/三角形的终点超前于手指，跟手时尺寸虚大。
      return Freehand.regularizeShape(t, current);
    }
    // 自由书写外推 1~2 帧补偿采样延迟；吸附态点已规整，原样使用。
    return currentTool == null ? Freehand.predict(current) : current;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 静态场景走缓存：内容未变时直接复用上一帧录好的 Picture，
    // 每帧只重绘真正变化的部分（活动笔画 / 选中框 / 套索 / 放大窗）。
    // 书写时 setState 只改 _current，静态场景不会失效 —— 这是不掉帧的关键。
    canvas.drawPicture(scene.pictureFor(Size(w, h), _drawScene));
    if (current.length > 1) {
      _drawStroke(
        canvas,
        Stroke(
            id: 'tmp',
            tool: currentTool ?? tool,
            color: color.value,
            size: this.size,
            points: _previewPoints()),
      );
    }
    for (final s in selected) _drawStroke(canvas, s);
    if (selected.isNotEmpty) _drawSelection(canvas);
    if (lasso.length > 1) _drawLasso(canvas);
    if (selRect != null) _drawSelRect(canvas, selRect!);
    _drawObjHandles(canvas);
    // 缩放窗（放大窗）：书写时跟随笔尖显示局部 2× 放大
    if (AppSettings.instance.magnifier &&
        tool.isPenLike &&
        !tool.isLaser &&
        current.length > 1) {
      _drawMagnifier(canvas);
    }
  }

  /// 绘制背景 + 模板 + 图片 + 文本框 + 各图层笔迹。主画布与放大窗共用。
  void _drawScene(Canvas canvas) {
    if (bg != null) {
      canvas.drawImageRect(
        bg!,
        Rect.fromLTWH(0, 0, bg!.width.toDouble(), bg!.height.toDouble()),
        Rect.fromLTWH(0, 0, w, h),
        Paint(),
      );
    } else {
      final base = paperColor != null
          ? Color(paperColor!)
          : (_eye ? const Color(0xFFF5ECD7) : Colors.white);
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = base);
      if (template != PageTemplate.none) _drawTemplate(canvas);
    }
    for (final im in images) {
      final img = imgMap[im.id];
      if (img != null) {
        final iw = img.width.toDouble();
        final ih = img.height.toDouble();
        final src = im.crop != null
            ? Rect.fromLTWH(
                (im.crop!['sx'] ?? 0) * iw,
                (im.crop!['sy'] ?? 0) * ih,
                (im.crop!['sw'] ?? 1) * iw,
                (im.crop!['sh'] ?? 1) * ih,
              )
            : Rect.fromLTWH(0, 0, iw, ih);
        canvas.drawImageRect(
          img,
          src,
          Rect.fromLTWH(im.x, im.y, im.w, im.h),
          Paint(),
        );
      } else {
        canvas.drawRect(
          Rect.fromLTWH(im.x, im.y, im.w, im.h),
          Paint()..color = Colors.grey.shade200,
        );
      }
    }
    for (final tb in textBoxes) _drawTextBox(canvas, tb);
    for (final ly in layers) {
      if (!ly.visible) continue;
      for (final s in strokes) {
        if (s.layerId == ly.id) _drawStroke(canvas, s);
      }
    }
  }

  /// 放大窗：在笔尖处画一个 2× 放大的圆形局部视图（含已有笔迹与当前预览）。
  void _drawMagnifier(Canvas canvas) {
    final tip = current.last;
    const r = 70.0;
    const scale = 2.0;
    if (w <= r * 2 || h <= r * 2) return;
    final oc = Offset(
      tip.x.clamp(r, w - r),
      tip.y.clamp(r, h - r),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: oc, radius: r)));
    canvas.translate(oc.dx, oc.dy);
    canvas.scale(scale);
    canvas.translate(-oc.dx, -oc.dy);
    _drawScene(canvas);
    if (current.length > 1) {
      _drawStroke(
        canvas,
        Stroke(
            id: 'tmp',
            tool: currentTool ?? tool,
            color: color.value,
            size: this.size,
            points: _previewPoints()),
      );
    }
    canvas.restore();
    // 镜框
    canvas.drawCircle(oc, r,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3);
    canvas.drawCircle(oc, r + 1,
        Paint()..color = Colors.black12..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  void _drawTextBox(Canvas canvas, TextBox tb) {
    final box = Rect.fromLTWH(tb.x, tb.y, tb.w, tb.h);
    if (tb.bg != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(tb.radius)),
        Paint()..color = Color(tb.bg!),
      );
    }
    if (tb.border != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(tb.radius)),
        Paint()
          ..color = Color(tb.border!)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    if (tb.text.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: tb.text,
          style: TextStyle(
            color: Color(tb.color),
            fontSize: tb.fontSize,
            fontWeight: tb.bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: tb.align == 1
            ? TextAlign.center
            : tb.align == 2
            ? TextAlign.right
            : TextAlign.left,
      );
      tp.layout(maxWidth: tb.w);
      final off = tb.align == 1
          ? Offset(tb.x + (tb.w - tp.width) / 2, tb.y)
          : tb.align == 2
          ? Offset(tb.x + (tb.w - tp.width), tb.y)
          : Offset(tb.x, tb.y);
      tp.paint(canvas, off);
    }
    if (interactive) {
      canvas.drawRect(
        box,
        Paint()
          ..color = Colors.blue.withOpacity(0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  void _drawTemplate(Canvas canvas) {
    final lineColor = _eye ? const Color(0xFFD8C7A8) : const Color(0xFFE2E2E2);
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0;
    const step = 28.0;
    switch (template) {
      case PageTemplate.grid:
        for (double x = 0; x <= w; x += step) {
          canvas.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (double y = 0; y <= h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.line:
        for (double y = step; y <= h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.dot:
        for (double y = step; y <= h; y += step) {
          for (double x = step; x <= w; x += step) {
            canvas.drawCircle(Offset(x, y), 1.2, paint);
          }
        }
        break;
      case PageTemplate.cornell:
        // 康奈尔笔记：顶部标题 / 左侧提示 / 底部摘要
        canvas.drawLine(Offset(0, h * 0.13), Offset(w, h * 0.13), paint);
        canvas.drawLine(
            Offset(w * 0.28, h * 0.13), Offset(w * 0.28, h), paint);
        canvas.drawLine(Offset(0, h * 0.82), Offset(w, h * 0.82), paint);
        for (double y = h * 0.82 + step; y <= h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.week:
        // 周计划：7 列网格 + 顶部星期标题带
        const cols = 7;
        for (int i = 1; i < cols; i++) {
          final x = w * i / cols;
          canvas.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (double y = step; y <= h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        canvas.drawLine(Offset(0, step * 1.2), Offset(w, step * 1.2), paint);
        break;
      case PageTemplate.month:
        // 月历：顶部分隔带 + 7 列 × 6 行网格
        const cols = 7, rows = 6;
        final headH = step * 1.6;
        canvas.drawLine(Offset(0, headH), Offset(w, headH), paint);
        for (int i = 1; i < cols; i++) {
          final x = w * i / cols;
          canvas.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (int r = 1; r < rows; r++) {
          final y = headH + (h - headH) * r / rows;
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      case PageTemplate.todos:
      case PageTemplate.checklist:
        // 待办 / 清单：左侧复选框 + 横线
        for (double y = step; y <= h; y += step) {
          canvas.drawLine(Offset(step * 1.4, y), Offset(w, y), paint);
          canvas.drawRect(
            Rect.fromLTWH(8, y - step * 0.55, step * 0.7, step * 0.7),
            Paint()..color = lineColor..style = PaintingStyle.stroke..strokeWidth = 1,
          );
        }
        break;
      case PageTemplate.math:
        // 坐标方格纸：小格 + 每 5 格加重线
        const g = 14.0;
        for (double x = 0; x <= w; x += g) {
          final heavy = ((x / g).round() % 5 == 0);
          canvas.drawLine(Offset(x, 0), Offset(x, h),
              heavy ? paint : Paint()..color = lineColor..strokeWidth = 0.5);
        }
        for (double y = 0; y <= h; y += g) {
          final heavy = ((y / g).round() % 5 == 0);
          canvas.drawLine(Offset(0, y), Offset(w, y),
              heavy ? paint : Paint()..color = lineColor..strokeWidth = 0.5);
        }
        break;
      case PageTemplate.music:
        // 五线谱：每组 5 线，逐组向下平移
        const staffGap = 9.0;
        const groupGap = staffGap * 7;
        for (double top = step; top < h - staffGap * 5; top += groupGap) {
          for (int i = 0; i < 5; i++) {
            final y = top + i * staffGap;
            canvas.drawLine(Offset(0, y), Offset(w, y), paint);
          }
        }
        break;
      case PageTemplate.column2:
      case PageTemplate.column3:
        final n = template == PageTemplate.column2 ? 2 : 3;
        for (int i = 1; i < n; i++) {
          final x = w * i / n;
          canvas.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
        for (double y = step; y <= h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        break;
      default:
        break;
    }
  }

  /// 激光笔：模拟真实激光光束——由外到内 4 层 + 叠加混合。
  /// 参考 GoodNotes/Notein 截图：纯白极细内芯、红粉中层、扩散红色外晕。
  ///
  /// 注意：saveLayer 的 paint 不能用 BlendMode.plus —— plus 是加色混合，
  /// 白纸 (255,255,255) 加任何颜色都会被钳制回纯白，导致激光在空白处
  /// 完全不可见、只有压在深色笔迹上才显形。这里用默认 srcOver 合成，
  /// 保证白纸上照样发光。
  void _drawLaserStroke(Canvas canvas, Stroke s) {
    final base = Color(s.color);
    // 必须沿「中心线」描边，不能用 Freehand.buildPath() —— 后者返回的是
    // perfect_freehand 的**闭合轮廓多边形**（设计上给 PaintingStyle.fill 用的）。
    // 拿它配 stroke 样式，画出来的是笔迹外形的一圈**空心边线**：
    // 中间是空的，4 层辉光叠上去也只是一圈朦胧的细线，完全没有光束感。
    final cl = Freehand.centerline(s);
    if (cl.length < 2) return;
    final path = Path()
      ..moveTo(cl.first.dx, cl.first.dy);
    for (var i = 1; i < cl.length; i++) {
      path.lineTo(cl[i].dx, cl[i].dy);
    }

    // 独立图层仅为隔离各层的 maskFilter，正常 (srcOver) 合成回纸面。
    canvas.saveLayer(
      Rect.fromCenter(center: Offset.zero, width: 99999, height: 99999),
      Paint(),
    );

    // ── 第 1 层：最外层扩散光晕（极粗 + 重模糊 + 极低透明度）──
    final w1 = (s.size * 5.0).clamp(8.0, 120.0);
    canvas.drawPath(
      path,
      Paint()
        ..color = base.withOpacity(0.12)
        ..strokeWidth = w1
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, w1 * 0.45),
    );

    // ── 第 2 层：中层辉光（中等粗细 + 中模糊 + 中等透明度）──
    final w2 = (s.size * 2.4).clamp(4.0, 60.0);
    canvas.drawPath(
      path,
      Paint()
        ..color = base.withOpacity(0.35)
        ..strokeWidth = w2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, w2 * 0.35),
    );

    // ── 第 3 层：内层亮芯前奏（较细 + 轻模糊 + 高饱和）──
    final w3 = (s.size * 1.2).clamp(2.0, 30.0);
    canvas.drawPath(
      path,
      Paint()
        ..color = base.withOpacity(0.75)
        ..strokeWidth = w3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, w3 * 0.18),
    );

    // ── 第 4 层：纯白/近白极细内芯（无模糊，激光的"高能中心"）──
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFFFFF) // 纯白内芯
        ..strokeWidth = (s.size * 0.38).clamp(0.6, 12.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    // ── 笔尖光点：末端一个小亮点，强化"激光点"感 ──
    if (s.points.isNotEmpty) {
      final last = s.points.last;
      final c = Offset(last.x, last.y);
      // 外圈柔光
      canvas.drawCircle(
        c, (s.size * 1.0).clamp(2.0, 35.0),
        Paint()
          ..color = base.withOpacity(0.25)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.size * 0.5),
      );
      // 内核白点
      canvas.drawCircle(
        c, (s.size * 0.35).clamp(0.6, 10.0),
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }

    canvas.restore();
  }

  void _drawStroke(Canvas canvas, Stroke s) {
    // 彩虹笔：沿笔迹按累计弧长做色相循环（单色填充路径无法表达渐变，故逐段描线）
    if (s.tool == Tool.rainbow) {
      final pts = Freehand.centerline(s);
      if (pts.length >= 2) {
        double total = 0;
        for (var i = 1; i < pts.length; i++) {
          total += (pts[i] - pts[i - 1]).distance;
        }
        double acc = 0;
        const cycles = 1.5; // 整笔色相循环圈数
        final paint = Paint()
          ..strokeWidth = s.size
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
        for (var i = 1; i < pts.length; i++) {
          final seg = (pts[i] - pts[i - 1]).distance;
          acc += seg;
          final hue = total > 0 ? (acc / total * 360 * cycles) % 360 : 0.0;
          paint.color = HSVColor.fromAHSV(1.0, hue, 0.95, 1.0).toColor();
          canvas.drawLine(pts[i - 1], pts[i], paint);
        }
      }
      return;
    }
    // 激光笔：多层外发光 + 亮芯 + 笔尖光点，做出「发光光束」的观感
    if (s.tool == Tool.laser) {
      _drawLaserStroke(canvas, s);
      return;
    }
    final isTape = s.tool == Tool.tape;
    final path = Freehand.buildPath(s);
    final op = isTape ? (s.opacity * 0.5).clamp(0.0, 1.0) : s.opacity;
    final paint = Paint()
      ..color = Color(s.color).withOpacity(op)
      ..strokeWidth = s.size
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (s.isShape) {
      final closed = s.tool == Tool.rect ||
          s.tool == Tool.ellipse ||
          s.tool == Tool.triangle;
      if (closed && AppSettings.instance.fillShape) {
        final fo = (s.opacity * AppSettings.instance.fillOpacity).clamp(0.0, 1.0);
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(s.color).withOpacity(fo)
            ..style = PaintingStyle.fill,
        );
      }
      paint.style = PaintingStyle.stroke;
      canvas.drawPath(path, paint);
    } else {
      paint.style = PaintingStyle.fill;
      canvas.drawPath(path, paint);
      if (isTape) {
        // 胶带边缘高光，增强“可剥离覆盖层”观感
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white.withOpacity(0.18)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  Rect _boundsOf(List<Stroke> ss) {
    // 复用 Geometry 的 AABB 缓存，避免每帧全点重算
    return Geometry.aabbOfStrokes(ss);
  }

  void _drawSelection(Canvas canvas) {
    final b = _boundsOf(selected).inflate(4);
    final border = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(b, border);
    final c = b.center;
    final corners = [b.topLeft, b.topRight, b.bottomLeft, b.bottomRight];
    final cp = Paint()..color = Colors.blue;
    for (final p in corners) {
      canvas.drawRect(Rect.fromCenter(center: p, width: 10, height: 10), cp);
    }
    // 旋转手柄
    final rot = Offset(c.dx, b.top - 28);
    canvas.drawLine(Offset(c.dx, b.top), rot, border);
    canvas.drawCircle(rot, 6, Paint()..color = Colors.blue);
    // 删除手柄
    final del = b.topRight + const Offset(22, -22);
    canvas.drawCircle(del, 11, Paint()..color = Colors.red);
    canvas.drawLine(del - const Offset(5, 5), del + const Offset(5, 5),
        Paint()..color = Colors.white..strokeWidth = 2);
    canvas.drawLine(del + const Offset(-5, 5), del + const Offset(5, -5),
        Paint()..color = Colors.white..strokeWidth = 2);
    // 改色色板（套索选中后改色）：贴着选区下沿排一行
    final swRects = _swatchRectsFor(b);
    for (var i = 0; i < swRects.length; i++) {
      final r = swRects[i];
      canvas.drawRect(r,
          Paint()..color = _lassoSwatches[i]..style = PaintingStyle.fill);
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.black26
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  /// 矩形框选（方框选择）的预览：半透明填充 + 虚线框。
  void _drawSelRect(Canvas canvas, Rect r) {
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.blueAccent.withOpacity(0.10)
        ..style = PaintingStyle.fill,
    );
    _drawDashedRect(
      canvas,
      r,
      Paint()
        ..color = Colors.blueAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
      6,
      4,
    );
  }

  /// 沿矩形四边画虚线。
  void _drawDashedRect(
      Canvas canvas, Rect r, Paint paint, double dash, double gap) {
    final pts = <Offset>[
      r.topLeft,
      r.topRight,
      r.bottomRight,
      r.bottomLeft,
      r.topLeft,
    ];
    for (var i = 0; i < 4; i++) {
      final a = pts[i], b = pts[i + 1];
      final len = (b - a).distance;
      if (len <= 0) continue;
      final dir = (b - a) / len;
      var t = 0.0;
      while (t < len) {
        final e = (t + dash) > len ? len : t + dash;
        canvas.drawLine(a + dir * t, a + dir * e, paint);
        t = e + gap;
      }
    }
  }

  /// 图片 / 文本框 选中态：外框 + 右下角缩放手柄。
  void _drawObjHandles(Canvas canvas) {
    final id = selObjId;
    if (id == null) return;
    Rect? r;
    if (selObjIsImage) {
      for (final im in images) {
        if (im.id == id) {
          r = Rect.fromLTWH(im.x, im.y, im.w, im.h);
          break;
        }
      }
    } else {
      for (final tb in textBoxes) {
        if (tb.id == id) {
          r = Rect.fromLTWH(tb.x, tb.y, tb.w, tb.h);
          break;
        }
      }
    }
    if (r == null) return;
    final box = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(r, box);
    // 缩放手柄（右下角）：白底 + 蓝框 + 斜箭头，暗示可拖动缩放
    final h = Rect.fromLTWH(r.right - 11, r.bottom - 11, 22, 22);
    canvas.drawRect(h, Paint()..color = Colors.white);
    canvas.drawRect(h, box);
    canvas.drawLine(
      Offset(h.left + 5, h.bottom - 5),
      Offset(h.right - 5, h.top + 5),
      Paint()
        ..color = Colors.blueAccent
        ..strokeWidth = 2,
    );
  }

  void _drawLasso(Canvas canvas) {
    final path = Path();
    path.moveTo(lasso.first.dx, lasso.first.dy);
    for (final p in lasso.skip(1)) path.lineTo(p.dx, p.dy);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) {
    // 护眼/主题模式会改变静态场景的纸张底色，但切换主题时 widget 参数不变，
    // didUpdateWidget 不会触发 —— 必须在这里显式失效，否则缓存会残留旧底色。
    if (old._eye != _eye) scene.invalidate();
    return true;
  }
}

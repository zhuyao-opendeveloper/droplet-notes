import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/custom_brush.dart';
import 'widgets/anim.dart';

enum AppThemeMode { light, dark, eyeCare, system }

enum IconStyle { outlined, filled }

/// 界面色彩主题（与亮/暗/护眼模式正交：模式决定明暗，色彩决定品牌主色）。
/// 由 M3 colorSchemeSeed 自动派生整套协调配色。
enum AppColorTheme {
  indigo('靛蓝', Color(0xFF3B5BDB)), // 默认：沉稳靛蓝
  teal('青碧', Color(0xFF00897B)),
  green('松绿', Color(0xFF2E7D32)),
  violet('紫罗兰', Color(0xFF7B1FA2)),
  rose('玫粉', Color(0xFFD81B60)),
  amber('琥珀', Color(0xFFFF8F00)),
  slate('墨灰', Color(0xFF455A64)),
  brown('赭石', Color(0xFF6D4C41));

  final String label;
  final Color seed;
  const AppColorTheme(this.label, this.seed);
}

/// 全局设置（主题 / 图标风格），持久化到 SharedPreferences。
class AppSettings {
  static final AppSettings instance = AppSettings._();
  AppThemeMode themeMode = AppThemeMode.light;
  AppColorTheme colorTheme = AppColorTheme.indigo; // 界面色彩主题（多套内置配色）
  IconStyle iconStyle = IconStyle.outlined;
  bool leftHand = false; // 左手模式：工具栏靠右
  bool immersive = false; // 全屏沉浸：编辑时隐藏系统状态栏/导航栏
  String? lockPin; // 应用锁 PIN（null = 未开启）
  bool usePressure = true; // 压感总开关（关闭则笔宽恒定，适合无压感设备）
  // —— 压感三件套（对标 GoodNotes）——
  bool penPressure = true; // 钢笔独立压感开关
  bool brushPressure = true; // 画笔独立压感开关
  double pressureOffset = 0.28; // pressureOffset：最快处保留的笔压基线 0..1
  double pressureDamping = 0.55; // pressureDamping：笔压 EMA 阻尼 0..1（越大越平滑）
  double pressureEstimation = 0.62; // 无笔时速度→笔压增益 0..1
  double tipSharpness = 0.5; // 笔尖锐度 0..1（端点收尖 + 宽度对比）
  double penSensitivity = 1.0; // pressure_sensitivity_fountain：钢笔灵敏度 0.3..2
  double brushSensitivity = 1.0; // pressure_sensitivity_brush：画笔灵敏度 0.3..2
  // —— 曲线平滑 ——
  bool lineSmoothing = true; // stylus_option_line_smoothing：线条平滑开关
  double curveSmoothing = 0.6; // -myscript-pen-smoothing：拟合平滑强度 0..1
  bool autoBackup = false; // 自动备份整个笔记库到本地备份目录
  String ocrScript = 'chinese'; // 文字识别语言：chinese/latin/japanese/korean
  bool palmReject = true; // 手掌防误触：有触控笔按下时忽略手指触摸
  bool magnifier = true; // 书写时显示跟随笔尖的放大窗（缩放窗）
  bool shapeRecognition = true; // 手绘图形识别：手写笔随手画的直线/圆/方/三角/箭头自动规整
  bool shapeHoldSnap = true; // 按住吸附：画完后笔尖停留 ~0.5s 才规整（关=抬笔即规整）
  double shapeTolerance = 0.5; // 形状识别宽严 0..1（越大越容易识别成规整图形）

  // —— 显示（Notein §3.2 Display）——
  String dateFormat = 'YYYY年MM月dd日'; // 日期格式
  bool keepScreenOn = false; // 保持屏幕常亮
  bool colorInversion = false; // 暗黑模式颜色反转（设置已保存，深色主题下后续版本生效）

  // —— 手势（Notein §3.3 Gesture）——
  bool twoFingerUndo = true; // 双指单击撤销
  bool threeFingerRedo = true; // 三指单击重做
  bool twoFingerSwipeMove = false; // 双指滑动移动页面
  int doubleTapZoom = 3; // 单指双击缩放：0 禁用 / 1 横向 / 2 纵向 / 3 双向

  // —— 页面设置（Notein §3.4 Page）——
  int pageTurnMode = 0; // 0 单页 / 1 连续滚动
  int pageAddMode = 0; // 加页方式：0 自动 / 1 手动
  int pageNumberPos = 0; // 页码位置 / 起始方向
  bool pdfTextSelect = true; // PDF 文字选择
  bool freeMovingPage = false; // 页面自由移动
  double pageSlidingResistance = 0.4; // 页面滑动阻力 0..1（默认 40%）
  bool penWithScale = true; // 笔画随页面缩放

  // —— 工具设置（Notein §3.5 Tool）——
  bool pressureEraser = false; // 压感橡皮：笔尖按压停顿自动切橡皮
  bool fingerPressureEraser = false; // 手指压感橡皮
  bool showUndoRedo = true; // 显示撤销-重做按钮
  bool showLayerOp = false; // 显示移动图层图标
  bool immersiveToolbar = false; // 沉浸式工具栏
  int toolbarStyle = 0; // 0 传统 / 1 沉浸
  bool toolCollection = true; // 笔盒收藏夹（最多 20 支）
  bool eraseTapeOnly = false; // 仅擦胶带

  // —— 自定义画笔（数据驱动，可可视化编辑 + JSON 编写/导入/导出）——
  List<CustomBrush> customBrushes = [];
  bool selectStrokesOnly = false; // 只选中笔迹（后续版本接入编辑器）

  // —— 辅助线与图形（Notein §3.6 Guides & Shapes）——
  bool showGuides = false; // 显示辅助线
  bool angleCorrection = false; // 角度矫正
  bool shapeAlignment = false; // 图形对齐
  double rulerAngle = 0.0; // 尺子角度（度）
  bool fillShape = false; // 图形填充
  double fillOpacity = 1.0; // 图形填充不透明度 0..1

  // —— 笔按键功能（Notein §3.8 Pen key mapping）——
  int penKeyAction = 0; // 0 切橡皮 / 1 切上一工具 / 2 撤销（后续版本接入编辑器）

  // —— 语言（Notein §3.9 Language）：0 跟随 / 1 英语 / 2 简体中文 / 3 繁体中文 ——
  int language = 0;

  // —— 其他（Notein §3.1 其他）——
  bool autoUpdate = false; // 自动更新

  bool get lockEnabled => lockPin != null;

  /// 还原初始设置（Notein「Reset to Defaults」）：把所有字段重置为默认值并落盘。
  /// 注意：云同步 / 自动备份按 Notein 文案应在还原后自动关闭——本版离线，备份保持现状。
  Future<void> resetToDefaults() async {
    final d = AppSettings._();
    themeMode = d.themeMode;
    iconStyle = d.iconStyle;
    leftHand = d.leftHand;
    immersive = d.immersive;
    lockPin = d.lockPin;
    usePressure = d.usePressure;
    penPressure = d.penPressure;
    brushPressure = d.brushPressure;
    pressureOffset = d.pressureOffset;
    pressureDamping = d.pressureDamping;
    pressureEstimation = d.pressureEstimation;
    tipSharpness = d.tipSharpness;
    penSensitivity = d.penSensitivity;
    brushSensitivity = d.brushSensitivity;
    lineSmoothing = d.lineSmoothing;
    curveSmoothing = d.curveSmoothing;
    autoBackup = d.autoBackup;
    ocrScript = d.ocrScript;
    palmReject = d.palmReject;
    magnifier = d.magnifier;
    shapeRecognition = d.shapeRecognition;
    shapeHoldSnap = d.shapeHoldSnap;
    shapeTolerance = d.shapeTolerance;
    dateFormat = d.dateFormat;
    keepScreenOn = d.keepScreenOn;
    colorInversion = d.colorInversion;
    twoFingerUndo = d.twoFingerUndo;
    threeFingerRedo = d.threeFingerRedo;
    twoFingerSwipeMove = d.twoFingerSwipeMove;
    doubleTapZoom = d.doubleTapZoom;
    pageTurnMode = d.pageTurnMode;
    pageAddMode = d.pageAddMode;
    pageNumberPos = d.pageNumberPos;
    pdfTextSelect = d.pdfTextSelect;
    freeMovingPage = d.freeMovingPage;
    pageSlidingResistance = d.pageSlidingResistance;
    penWithScale = d.penWithScale;
    pressureEraser = d.pressureEraser;
    fingerPressureEraser = d.fingerPressureEraser;
    showUndoRedo = d.showUndoRedo;
    showLayerOp = d.showLayerOp;
    immersiveToolbar = d.immersiveToolbar;
    toolbarStyle = d.toolbarStyle;
    toolCollection = d.toolCollection;
    eraseTapeOnly = d.eraseTapeOnly;
    selectStrokesOnly = d.selectStrokesOnly;
    showGuides = d.showGuides;
    angleCorrection = d.angleCorrection;
    shapeAlignment = d.shapeAlignment;
    rulerAngle = d.rulerAngle;
    fillShape = d.fillShape;
    fillOpacity = d.fillOpacity;
    penKeyAction = d.penKeyAction;
    language = d.language;
    autoUpdate = d.autoUpdate;
    customBrushes = CustomBrush.defaults();
    await save();
  }

  AppSettings._();

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    themeMode = AppThemeMode.values[p.getInt('theme') ?? 0];
    final ct = p.getInt('colorTheme') ?? 0;
    colorTheme = (ct >= 0 && ct < AppColorTheme.values.length)
        ? AppColorTheme.values[ct]
        : AppColorTheme.indigo;
    iconStyle = IconStyle.values[p.getInt('icon') ?? 0];
    leftHand = p.getBool('leftHand') ?? false;
    immersive = p.getBool('immersive') ?? false;
    usePressure = p.getBool('usePressure') ?? true;
    penPressure = p.getBool('penPressure') ?? true;
    brushPressure = p.getBool('brushPressure') ?? true;
    pressureOffset = p.getDouble('pressureOffset') ?? 0.28;
    pressureDamping = p.getDouble('pressureDamping') ?? 0.55;
    pressureEstimation = p.getDouble('pressureEstimation') ?? 0.62;
    tipSharpness = p.getDouble('tipSharpness') ?? 0.5;
    penSensitivity = p.getDouble('penSensitivity') ?? 1.0;
    brushSensitivity = p.getDouble('brushSensitivity') ?? 1.0;
    lineSmoothing = p.getBool('lineSmoothing') ?? true;
    curveSmoothing = p.getDouble('curveSmoothing') ?? 0.6;
    autoBackup = p.getBool('autoBackup') ?? false;
    ocrScript = p.getString('ocrScript') ?? 'chinese';
    palmReject = p.getBool('palmReject') ?? true;
    magnifier = p.getBool('magnifier') ?? true;
    shapeRecognition = p.getBool('shapeRecognition') ?? true;
    shapeHoldSnap = p.getBool('shapeHoldSnap') ?? true;
    shapeTolerance = p.getDouble('shapeTolerance') ?? 0.5;
    dateFormat = p.getString('dateFormat') ?? 'YYYY年MM月dd日';
    keepScreenOn = p.getBool('keepScreenOn') ?? false;
    colorInversion = p.getBool('colorInversion') ?? false;
    twoFingerUndo = p.getBool('twoFingerUndo') ?? true;
    threeFingerRedo = p.getBool('threeFingerRedo') ?? true;
    twoFingerSwipeMove = p.getBool('twoFingerSwipeMove') ?? false;
    doubleTapZoom = p.getInt('doubleTapZoom') ?? 3;
    pageTurnMode = p.getInt('pageTurnMode') ?? 0;
    pageAddMode = p.getInt('pageAddMode') ?? 0;
    pageNumberPos = p.getInt('pageNumberPos') ?? 0;
    pdfTextSelect = p.getBool('pdfTextSelect') ?? true;
    freeMovingPage = p.getBool('freeMovingPage') ?? false;
    pageSlidingResistance = p.getDouble('pageSlidingResistance') ?? 0.4;
    penWithScale = p.getBool('penWithScale') ?? true;
    pressureEraser = p.getBool('pressureEraser') ?? false;
    fingerPressureEraser = p.getBool('fingerPressureEraser') ?? false;
    showUndoRedo = p.getBool('showUndoRedo') ?? true;
    showLayerOp = p.getBool('showLayerOp') ?? false;
    immersiveToolbar = p.getBool('immersiveToolbar') ?? false;
    toolbarStyle = p.getInt('toolbarStyle') ?? 0;
    toolCollection = p.getBool('toolCollection') ?? true;
    eraseTapeOnly = p.getBool('eraseTapeOnly') ?? false;
    selectStrokesOnly = p.getBool('selectStrokesOnly') ?? false;
    showGuides = p.getBool('showGuides') ?? false;
    angleCorrection = p.getBool('angleCorrection') ?? false;
    shapeAlignment = p.getBool('shapeAlignment') ?? false;
    rulerAngle = p.getDouble('rulerAngle') ?? 0.0;
    fillShape = p.getBool('fillShape') ?? false;
    fillOpacity = p.getDouble('fillOpacity') ?? 1.0;
    penKeyAction = p.getInt('penKeyAction') ?? 0;
    language = p.getInt('language') ?? 0;
    autoUpdate = p.getBool('autoUpdate') ?? false;
    lockPin = p.getString('lockPin');
    // 自定义画笔：首次启动（无键）播种起始笔刷；解析失败兜底回默认值。
    final cbRaw = p.getString('custom_brushes');
    if (cbRaw == null) {
      customBrushes = CustomBrush.defaults();
    } else {
      try {
        final list = jsonDecode(cbRaw) as List;
        customBrushes =
            list.map((e) => CustomBrush.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        customBrushes = CustomBrush.defaults();
      }
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('theme', themeMode.index);
    await p.setInt('colorTheme', colorTheme.index);
    await p.setInt('icon', iconStyle.index);
    await p.setBool('leftHand', leftHand);
    await p.setBool('immersive', immersive);
    await p.setBool('usePressure', usePressure);
    await p.setBool('penPressure', penPressure);
    await p.setBool('brushPressure', brushPressure);
    await p.setDouble('pressureOffset', pressureOffset);
    await p.setDouble('pressureDamping', pressureDamping);
    await p.setDouble('pressureEstimation', pressureEstimation);
    await p.setDouble('tipSharpness', tipSharpness);
    await p.setDouble('penSensitivity', penSensitivity);
    await p.setDouble('brushSensitivity', brushSensitivity);
    await p.setBool('lineSmoothing', lineSmoothing);
    await p.setDouble('curveSmoothing', curveSmoothing);
    await p.setBool('autoBackup', autoBackup);
    await p.setString('ocrScript', ocrScript);
    await p.setBool('palmReject', palmReject);
    await p.setBool('magnifier', magnifier);
    await p.setBool('shapeRecognition', shapeRecognition);
    await p.setBool('shapeHoldSnap', shapeHoldSnap);
    await p.setDouble('shapeTolerance', shapeTolerance);
    await p.setString('dateFormat', dateFormat);
    await p.setBool('keepScreenOn', keepScreenOn);
    await p.setBool('colorInversion', colorInversion);
    await p.setBool('twoFingerUndo', twoFingerUndo);
    await p.setBool('threeFingerRedo', threeFingerRedo);
    await p.setBool('twoFingerSwipeMove', twoFingerSwipeMove);
    await p.setInt('doubleTapZoom', doubleTapZoom);
    await p.setInt('pageTurnMode', pageTurnMode);
    await p.setInt('pageAddMode', pageAddMode);
    await p.setInt('pageNumberPos', pageNumberPos);
    await p.setBool('pdfTextSelect', pdfTextSelect);
    await p.setBool('freeMovingPage', freeMovingPage);
    await p.setDouble('pageSlidingResistance', pageSlidingResistance);
    await p.setBool('penWithScale', penWithScale);
    await p.setBool('pressureEraser', pressureEraser);
    await p.setBool('fingerPressureEraser', fingerPressureEraser);
    await p.setBool('showUndoRedo', showUndoRedo);
    await p.setBool('showLayerOp', showLayerOp);
    await p.setBool('immersiveToolbar', immersiveToolbar);
    await p.setInt('toolbarStyle', toolbarStyle);
    await p.setBool('toolCollection', toolCollection);
    await p.setBool('eraseTapeOnly', eraseTapeOnly);
    await p.setBool('selectStrokesOnly', selectStrokesOnly);
    await p.setBool('showGuides', showGuides);
    await p.setBool('angleCorrection', angleCorrection);
    await p.setBool('shapeAlignment', shapeAlignment);
    await p.setDouble('rulerAngle', rulerAngle);
    await p.setBool('fillShape', fillShape);
    await p.setDouble('fillOpacity', fillOpacity);
    await p.setInt('penKeyAction', penKeyAction);
    await p.setInt('language', language);
    await p.setBool('autoUpdate', autoUpdate);
    await p.setString('custom_brushes',
        jsonEncode(customBrushes.map((b) => b.toJson()).toList()));
    if (lockPin == null) {
      await p.remove('lockPin');
    } else {
      await p.setString('lockPin', lockPin!);
    }
  }

  /// 新增或更新一支自定义画笔并落盘。
  void upsertCustomBrush(CustomBrush b) {
    final i = customBrushes.indexWhere((x) => x.id == b.id);
    if (i >= 0) {
      customBrushes[i] = b;
    } else {
      customBrushes.add(b);
    }
    save();
  }

  /// 删除一支自定义画笔并落盘。
  void removeCustomBrush(String id) {
    customBrushes.removeWhere((x) => x.id == id);
    save();
  }
}

/// 三套显示模式：亮 / 暗 / 护眼（暖色低蓝光）。
/// 模式与色彩主题正交：亮/暗/自动共用用户选中的品牌 seed（护眼固定暖琥珀 +
/// 米黄底色以保证低蓝光效果），由 M3 自动派生整套协调配色。
class AppThemes {
  static ThemeData of(AppThemeMode mode, {AppColorTheme? colorTheme}) {
    // 未显式传入时读全局设置（持久化的用户选择，默认靛蓝）。
    final seed = (colorTheme ?? AppSettings.instance.colorTheme).seed;
    switch (mode) {
      case AppThemeMode.light:
        return _decorate(ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: seed,
        ));
      case AppThemeMode.dark:
        return _decorate(ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: seed,
          scaffoldBackgroundColor: const Color(0xFF121319),
          canvasColor: const Color(0xFF121319),
        ));
      case AppThemeMode.eyeCare:
        // 护眼模式保持暖琥珀 + 米黄底（低蓝光是本模式的核心诉求，
        // 不随色彩主题换 seed，否则"护眼"就名存实亡了）。
        return _decorate(ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: Colors.amber,
          scaffoldBackgroundColor: const Color(0xFFF5ECD7),
          canvasColor: const Color(0xFFF5ECD7),
        ));
      case AppThemeMode.system:
        // 通常由 AppRoot 在调用前解析为 light/dark；此处兜底返回浅色。
        return _decorate(ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: seed,
        ));
    }
  }

  /// 三套主题共用的动效 / 反馈 / 形状配置，让整套 UI 更现代、统一：
  /// - 页面转场统一「淡入 + 轻微上移」
  /// - AppBar 扁平化、随滚动轻微抬升
  /// - 卡片 / 按钮 / 对话框 / 底部菜单 / 弹窗统一大圆角
  /// - 输入框、分割线、列表项间距统一
  static ThemeData _decorate(ThemeData base) => base.copyWith(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: AppPageTransitionsBuilder(),
            TargetPlatform.iOS: AppPageTransitionsBuilder(),
            TargetPlatform.macOS: AppPageTransitionsBuilder(),
            TargetPlatform.windows: AppPageTransitionsBuilder(),
            TargetPlatform.linux: AppPageTransitionsBuilder(),
          },
        ),
        appBarTheme: AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 1,
          backgroundColor: base.colorScheme.surface,
          foregroundColor: base.colorScheme.onSurface,
        ),
        cardTheme: CardTheme(
          elevation: 1,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        dividerTheme: const DividerThemeData(space: 1, thickness: 1),
        listTileTheme: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: 16),
          minLeadingWidth: 8,
        ),
        dialogTheme: DialogTheme(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 3,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          showDragHandle: true,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 3,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
}

/// 根据当前图标风格选择 Fluent 线性 / 填充图标，直接返回 Icon Widget。
Widget flu(IconData regular, IconData filled) =>
    Icon(AppSettings.instance.iconStyle == IconStyle.filled ? filled : regular);

/// 主题变更通知（设置页改变主题后驱动 MaterialApp 重建）。
final ValueNotifier<AppThemeMode> themeNotifier =
    ValueNotifier(AppSettings.instance.themeMode);

/// 任意需要驱动 MaterialApp 重建的设置变更（主题 / 语言）通过此通知计数。
final ValueNotifier<int> uiVersion = ValueNotifier(0);

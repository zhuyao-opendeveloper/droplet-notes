import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard：复制仓库地址
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../l10n.dart';
import '../ocr/ocr_index.dart';
import '../ocr/ocr_service.dart';
import '../storage/backup.dart';
import '../storage/note_store.dart';
import '../theme.dart';
import '../widgets/anim.dart';
import 'licenses.dart';

/// 设置中心（Notein §3 完整设置树）。
/// 主列表按「文档设置 / 其他 / 同步·备份」分组，点按进入对应详情页。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const List<_Group> _groups = [
    _Group('sec_document', [
      _Item('page', 'sec_page_settings', FluentIcons.page_fit_24_regular),
      _Item('tool', 'sec_tool_settings', FluentIcons.pen_24_regular),
      _Item('guides', 'sec_guides', FluentIcons.ruler_24_regular),
    ]),
    _Group('sec_other', [
      _Item('display', 'sec_display', FluentIcons.dark_theme_24_regular),
      _Item('language', 'sec_language', FluentIcons.local_language_24_regular),
      _Item('gesture', 'sec_gesture', FluentIcons.gesture_24_regular),
      _Item('penkey', 'sec_pen_shortcut', FluentIcons.pen_24_regular),
      _Item('ocr', 'sec_ocr', FluentIcons.book_24_regular),
      _Item('security', 'sec_security', FluentIcons.shield_24_regular),
      _Item('about', 'sec_about', FluentIcons.info_24_regular),
      _Item('reset', 'reset_defaults', FluentIcons.arrow_reset_24_regular),
    ]),
    _Group('sec_sync_backup', [
      _Item('cloudsync', 'cloud_sync', FluentIcons.cloud_24_regular),
      _Item('cloudbackup', 'cloud_backup', FluentIcons.cloud_arrow_up_24_regular),
      _Item('localbackup', 'local_backup', FluentIcons.folder_24_regular),
    ]),
  ];

  @override
  Widget build(BuildContext ctx) => Scaffold(
        appBar: AppBar(title: Text(L.tr(ctx, 'settings_title'))),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final g in _groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(L.tr(ctx, g.titleKey),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(ctx).colorScheme.primary)),
              ),
              for (final it in g.items)
                FadeSlideIn(
                  child: ListTile(
                    leading: flu(it.icon, it.icon),
                    title: Text(L.tr(ctx, it.titleKey)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      ctx,
                      MaterialPageRoute(
                          builder: (_) => SettingsDetailPage(itemId: it.id)),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      );
}

class _Group {
  final String titleKey;
  final List<_Item> items;
  const _Group(this.titleKey, this.items);
}

class _Item {
  final String id;
  final String titleKey;
  final IconData icon;
  const _Item(this.id, this.titleKey, this.icon);
}

class SettingsDetailPage extends StatefulWidget {
  final String itemId;
  const SettingsDetailPage({super.key, required this.itemId});
  @override
  State<SettingsDetailPage> createState() => _SettingsDetailPageState();
}

class _SettingsDetailPageState extends State<SettingsDetailPage> {
  int _indexedPages = 0;

  @override
  void initState() {
    super.initState();
    if (widget.itemId == 'ocr') _refreshIndexCount();
  }

  Future<void> _refreshIndexCount() async {
    final c = await OcrIndex.indexedPageCount();
    if (mounted) setState(() => _indexedPages = c);
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  void _bumpUI() => uiVersion.value++;

  Future<void> _setPin() async {
    String buf = '';
    String? confirm;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(confirm == null ? '设置 4 位 PIN' : '再次输入确认'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(buf.length == 4 ? '已输入 4 位，点击确认' : '已输入 ${buf.length}/4'),
              const SizedBox(height: 8),
              Wrap(
                children: List.generate(
                  10,
                  (i) => Padding(
                    padding: const EdgeInsets.all(4),
                    child: ElevatedButton(
                      onPressed: () {
                        if (buf.length < 4) {
                          buf += '$i';
                          setD(() {});
                        }
                      },
                      child: Text('$i'),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (buf.isNotEmpty) {
                    buf = buf.substring(0, buf.length - 1);
                    setD(() {});
                  }
                },
                child: const Text('删除'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L.tr(ctx, 'cancel'))),
            TextButton(
              onPressed: () {
                if (buf.length == 4) {
                  if (confirm == null) {
                    confirm = buf;
                    buf = '';
                    setD(() {});
                  } else {
                    Navigator.pop(ctx, confirm == buf);
                  }
                }
              },
              child: Text(L.tr(ctx, 'confirm')),
            ),
          ],
        ),
      ),
    );
    if (ok == true && confirm != null) {
      AppSettings.instance.lockPin = confirm;
      await AppSettings.instance.save();
      setState(() {});
    } else if (ok == false && confirm != null) {
      _toast('两次输入不一致，请重试');
    }
  }

  Future<void> _rebuildIndex() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('建立全文索引'),
        content: const Text(
          '会把每一页渲染后逐页做离线文字识别，页数多时比较慢（约每页 1~3 秒），'
          '过程中请保持应用在前台。已有索引会被覆盖。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.tr(ctx, 'cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.tr(ctx, 'ok'))),
        ],
      ),
    );
    if (ok != true) return;
    final notes = await NoteStore().listNotes();
    final total = notes.fold<int>(0, (a, n) => a + n.pages.length);
    if (total == 0) {
      _toast('还没有笔记');
      return;
    }
    if (!mounted) return;
    final progress = ValueNotifier<String>('0 / $total');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 18),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text('识别中 $v'),
              ),
            ),
          ],
        ),
      ),
    );
    final eye = AppSettings.instance.themeMode == AppThemeMode.eyeCare;
    final script = AppSettings.instance.ocrScript;
    int done = 0, chars = 0;
    for (final n in notes) {
      for (int i = 0; i < n.pages.length; i++) {
        try {
          final r =
              await OcrService.recognizePage(n, i, script: script, eyeCare: eye);
          await OcrIndex.putPage(n.id, i, r.text);
          chars += r.charCount;
        } catch (_) {}
        done++;
        progress.value = '$done / $total';
      }
    }
    progress.dispose();
    if (mounted) Navigator.pop(context);
    await _refreshIndexCount();
    _toast('索引完成：$done 页，识别出 $chars 字');
  }

  /// 分组卡片
  Widget _card(String title, List<Widget> children, {int index = 0}) =>
      FadeSlideIn(
        delay: AppAnim.stagger * index,
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              ...children,
            ],
          ),
        ),
      );

  Widget _switch(String title, String subtitle, bool value,
          void Function(bool) onChanged,
          {int index = 0}) =>
      FadeSlideIn(
        delay: AppAnim.stagger * index,
        child: SwitchListTile(
          title: Text(title),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          value: value,
          onChanged: onChanged,
        ),
      );

  /// 分段选择（Wrap of ChoiceChip）
  Widget _segmented<T>({
    required List<(String, T)> options,
    required T value,
    required void Function(T) onChanged,
    int index = 0,
  }) =>
      FadeSlideIn(
        delay: AppAnim.stagger * index,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options
                .map((o) => ChoiceChip(
                      label: Text(o.$1),
                      selected: value == o.$2,
                      onSelected: (_) => onChanged(o.$2),
                    ))
                .toList(),
          ),
        ),
      );

  Widget _slider({
    required String title,
    required String label,
    required double value,
    required double min,
    required double max,
    required void Function(double) onChanged,
    required void Function(double) onEnd,
    int index = 0,
  }) =>
      FadeSlideIn(
        delay: AppAnim.stagger * index,
        child: ListTile(
          title: Text(title),
          subtitle: Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) * 20).round().clamp(1, 100),
            label: label,
            onChanged: onChanged,
            onChangeEnd: onEnd,
          ),
        ),
      );

  @override
  Widget build(BuildContext ctx) {
    final titleKey = _titleFor(widget.itemId);
    return Scaffold(
      appBar: AppBar(title: Text(L.tr(ctx, titleKey))),
      body: ListView(
        children: [
          ..._bodyFor(ctx, widget.itemId),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  String _titleFor(String id) => switch (id) {
        'page' => 'sec_page_settings',
        'tool' => 'sec_tool_settings',
        'guides' => 'sec_guides',
        'display' => 'sec_display',
        'language' => 'sec_language',
        'gesture' => 'sec_gesture',
        'penkey' => 'sec_pen_shortcut',
        'ocr' => 'sec_ocr',
        'security' => 'sec_security',
        'about' => 'sec_about',
        'reset' => 'reset_defaults',
        'cloudsync' => 'cloud_sync',
        'cloudbackup' => 'cloud_backup',
        'localbackup' => 'local_backup',
        _ => 'settings_title',
      };

  List<Widget> _bodyFor(BuildContext ctx, String id) {
    final s = AppSettings.instance;
    switch (id) {
      case 'page':
        return [
          _card(L.tr(ctx, 'sec_page_settings'), [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'page_turn_mode')),
            ),
            _segmented<int>(
              options: [
                (L.tr(ctx, 'page_single'), 0),
                (L.tr(ctx, 'page_continuous'), 1),
              ],
              value: s.pageTurnMode,
              onChanged: (v) => setState(() {
                s.pageTurnMode = v;
                s.save();
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'page_add_mode')),
            ),
            _segmented<int>(
              options: [
                (L.tr(ctx, 'page_add_auto'), 0),
                (L.tr(ctx, 'page_add_manual'), 1),
              ],
              value: s.pageAddMode,
              onChanged: (v) => setState(() {
                s.pageAddMode = v;
                s.save();
              }),
            ),
            _switch(L.tr(ctx, 'pdf_text_select'), '', s.pdfTextSelect,
                (v) => setState(() {
              s.pdfTextSelect = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'free_move_page'), '', s.freeMovingPage,
                (v) => setState(() {
              s.freeMovingPage = v;
              s.save();
            })),
            _slider(
              title: L.tr(ctx, 'page_resistance'),
              label: '${(s.pageSlidingResistance * 100).round()}%',
              value: s.pageSlidingResistance,
              min: 0,
              max: 1,
              onChanged: (v) => setState(() => s.pageSlidingResistance = v),
              onEnd: (_) => s.save(),
            ),
            _switch(L.tr(ctx, 'pen_with_scale'), '', s.penWithScale,
                (v) => setState(() {
              s.penWithScale = v;
              s.save();
            })),
          ], index: 0),
        ];
      case 'tool':
        return [
          _card(L.tr(ctx, 'sec_tool_settings'), [
            _switch(L.tr(ctx, 'pressure_eraser'), '', s.pressureEraser,
                (v) => setState(() {
              s.pressureEraser = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'finger_pressure_eraser'), '', s.fingerPressureEraser,
                (v) => setState(() {
              s.fingerPressureEraser = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'show_undo_redo'), '', s.showUndoRedo,
                (v) => setState(() {
              s.showUndoRedo = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'show_layer_op'), '', s.showLayerOp,
                (v) => setState(() {
              s.showLayerOp = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'immersive_toolbar'), '', s.immersiveToolbar,
                (v) => setState(() {
              s.immersiveToolbar = v;
              s.save();
            })),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'toolbar_style')),
            ),
            _segmented<int>(
              options: [
                (L.tr(ctx, 'traditional'), 0),
                (L.tr(ctx, 'immersive_toolbar'), 1),
              ],
              value: s.toolbarStyle,
              onChanged: (v) => setState(() {
                s.toolbarStyle = v;
                s.save();
              }),
            ),
            _switch(L.tr(ctx, 'tool_collection'), '', s.toolCollection,
                (v) => setState(() {
              s.toolCollection = v;
              s.save();
            })),
            _switch(
              L.tr(ctx, 'one_stroke_shape'),
              // 新规则：抬笔不再自动识别，必须画完不提笔、停留约 0.5 秒才触发。
              // 只认 直线 / 圆 / 光滑曲线 三类，识别后可继续拖动调整，抬笔吸附。
              '画完不提笔、停留约 0.5 秒才识别（仅直线 / 圆 / 光滑曲线），'
              '识别后可继续拖着改，抬笔才最终吸附',
              s.shapeRecognition,
                (v) => setState(() {
              s.shapeRecognition = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'erase_tape_only'), '', s.eraseTapeOnly ?? false,
                (v) => setState(() {
              s.eraseTapeOnly = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'select_strokes_only'), '', s.selectStrokesOnly ?? false,
                (v) => setState(() {
              s.selectStrokesOnly = v;
              s.save();
            })),
          ], index: 0),
        ];
      case 'guides':
        return [
          _card(L.tr(ctx, 'sec_guides'), [
            _switch(L.tr(ctx, 'show_guides'), '', s.showGuides,
                (v) => setState(() {
              s.showGuides = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'angle_correction'), '', s.angleCorrection,
                (v) => setState(() {
              s.angleCorrection = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'shape_alignment'), '', s.shapeAlignment,
                (v) => setState(() {
              s.shapeAlignment = v;
              s.save();
            })),
            _slider(
              title: L.tr(ctx, 'ruler_angle'),
              label: '${s.rulerAngle.round()}°',
              value: s.rulerAngle,
              min: 0,
              max: 360,
              onChanged: (v) => setState(() => s.rulerAngle = v),
              onEnd: (_) => s.save(),
            ),
            _switch(L.tr(ctx, 'fill_shape'), '', s.fillShape,
                (v) => setState(() {
              s.fillShape = v;
              s.save();
            })),
            _slider(
              title: L.tr(ctx, 'fill_opacity'),
              label: '${(s.fillOpacity * 100).round()}%',
              value: s.fillOpacity,
              min: 0,
              max: 1,
              onChanged: (v) => setState(() => s.fillOpacity = v),
              onEnd: (_) => s.save(),
            ),
          ], index: 0),
        ];
      case 'display':
        return [
          _card(L.tr(ctx, 'sec_display'), [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'display_mode')),
            ),
            _segmented<AppThemeMode>(
              options: [
                (L.tr(ctx, 'light'), AppThemeMode.light),
                (L.tr(ctx, 'dark'), AppThemeMode.dark),
                (L.tr(ctx, 'auto'), AppThemeMode.system),
                (L.tr(ctx, 'eye_care'), AppThemeMode.eyeCare),
              ],
              value: s.themeMode,
              onChanged: (v) => setState(() {
                s.themeMode = v;
                s.save();
                _bumpUI();
              }),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('界面配色'),
            ),
            // 多套内置色彩主题：色点 + 名称，M3 由 seed 自动派生整套 UI 配色。
            // 护眼模式固定暖琥珀（低蓝光），换配色主要作用于亮/暗/自动模式。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final t in AppColorTheme.values)
                    ChoiceChip(
                      avatar: CircleAvatar(
                        backgroundColor: t.seed,
                        radius: 9,
                        child: const SizedBox.shrink(),
                      ),
                      label: Text(t.label),
                      selected: s.colorTheme == t,
                      onSelected: (_) => setState(() {
                        s.colorTheme = t;
                        s.save();
                        _bumpUI();
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'date_format')),
            ),
            _segmented<String>(
              options: const [
                ('YYYY年MM月dd日', 'YYYY年MM月dd日'),
                ('YYYY-MM-dd', 'YYYY-MM-dd'),
                ('MM/dd/YYYY', 'MM/dd/YYYY'),
              ],
              value: s.dateFormat,
              onChanged: (v) => setState(() {
                s.dateFormat = v;
                s.save();
              }),
            ),
            _switch(L.tr(ctx, 'keep_screen_on'), L.tr(ctx, 'keep_screen_on_sub'),
                s.keepScreenOn, (v) async {
              setState(() => s.keepScreenOn = v);
              await s.save();
              await WakelockPlus.toggle(enable: v);
            }),
            _switch(L.tr(ctx, 'color_inversion'), '', s.colorInversion,
                (v) => setState(() {
              s.colorInversion = v;
              s.save();
            })),
          ], index: 0),
        ];
      case 'language':
        return [
          _card(L.tr(ctx, 'sec_language'), [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'sec_language')),
            ),
            _segmented<int>(
              options: const [
                ('跟随系统', 0),
                ('English', 1),
                ('简体中文', 2),
                ('繁體中文', 3),
              ],
              value: s.language,
              onChanged: (v) => setState(() {
                s.language = v;
                s.save();
                _bumpUI();
              }),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text('切换语言后界面文案将即时更新（部分第三方文案以系统语言为准）。',
                  style: TextStyle(fontSize: 12)),
            ),
          ], index: 0),
        ];
      case 'gesture':
        return [
          _card(L.tr(ctx, 'sec_gesture'), [
            _switch(L.tr(ctx, 'two_finger_undo'), '', s.twoFingerUndo,
                (v) => setState(() {
              s.twoFingerUndo = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'three_finger_redo'), '', s.threeFingerRedo,
                (v) => setState(() {
              s.threeFingerRedo = v;
              s.save();
            })),
            _switch(L.tr(ctx, 'two_finger_swipe_move'), '', s.twoFingerSwipeMove,
                (v) => setState(() {
              s.twoFingerSwipeMove = v;
              s.save();
            })),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'double_tap_zoom')),
            ),
            _segmented<int>(
              options: [
                (L.tr(ctx, 'zoom_disable'), 0),
                (L.tr(ctx, 'zoom_h'), 1),
                (L.tr(ctx, 'zoom_v'), 2),
                (L.tr(ctx, 'zoom_both'), 3),
              ],
              value: s.doubleTapZoom,
              onChanged: (v) => setState(() {
                s.doubleTapZoom = v;
                s.save();
              }),
            ),
          ], index: 0),
        ];
      case 'penkey':
        return [
          _card(L.tr(ctx, 'sec_pen_shortcut'), [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(L.tr(ctx, 'pen_key_action')),
            ),
            _segmented<int>(
              options: [
                (L.tr(ctx, 'pen_key_eraser'), 0),
                (L.tr(ctx, 'pen_key_last'), 1),
                (L.tr(ctx, 'pen_key_undo'), 2),
              ],
              value: s.penKeyAction,
              onChanged: (v) => setState(() {
                s.penKeyAction = v;
                s.save();
              }),
            ),
          ], index: 0),
        ];
      case 'ocr':
        return [
          _card(L.tr(ctx, 'sec_ocr'), [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Text(
                '引擎随应用打包、完全离线运行，不联网也不依赖 Google 服务。'
                '印刷体（PDF 扫描页、截图插图）识别最准，工整手写可用，连笔中文较差。',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(L.tr(ctx, 'sec_language')),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: OcrService.scripts.entries
                    .map((e) => ChoiceChip(
                          label: Text(e.value),
                          selected: s.ocrScript == e.key,
                          onSelected: (_) {
                            s.ocrScript = e.key;
                            s.save();
                            setState(() {});
                          },
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              title: Text(L.tr(ctx, 'sec_ocr')),
              subtitle: Text('已索引 $_indexedPages 页'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: _rebuildIndex,
                    icon: const Icon(Icons.auto_stories),
                    label: const Text('为全部笔记建索引'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _indexedPages == 0
                        ? null
                        : () async {
                            await OcrIndex.clearAll();
                            await _refreshIndexCount();
                            _toast('已清空索引');
                          },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('清空索引'),
                  ),
                ],
              ),
            ),
          ], index: 0),
        ];
      case 'security':
        return [
          _card(L.tr(ctx, 'sec_security'), [
            ListTile(
              title: Text(L.tr(ctx, 'app_lock')),
              subtitle: Text(s.lockEnabled ? '已开启（4 位 PIN）' : '未开启'),
              trailing: s.lockEnabled
                  ? TextButton(
                      onPressed: () async {
                        s.lockPin = null;
                        await s.save();
                        if (!mounted) return;
                        setState(() {});
                      },
                      child: Text(L.tr(ctx, 'close'),
                          style: const TextStyle(color: Colors.red)),
                    )
                  : ElevatedButton(
                      onPressed: _setPin,
                      child: Text(L.tr(ctx, 'set_pin')),
                    ),
            ),
          ], index: 0),
        ];
      case 'about':
        return [
          _card(L.tr(ctx, 'sec_about'), [
            const ListTile(
              title: Text('Hydro Note'),
              subtitle: Text('离线手写笔记 · 版本 0.1.0'),
            ),
            // 开源地址 + 求 Star：本作免费无广告、不联网、不收集任何数据，
            // 唯一能支持它继续做下去的方式就是给仓库点个 Star。
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('开源仓库'),
              subtitle: const Text(kRepoUrl),
              trailing: const Icon(Icons.copy),
              onTap: () async {
                await Clipboard.setData(const ClipboardData(text: kRepoUrl));
                if (!mounted) return;
                _toast('仓库地址已复制，粘到浏览器打开就能看到源码');
              },
            ),
            const ListTile(
              leading: Icon(Icons.star_border),
              title: Text('喜欢的话，给个 Star ⭐'),
              subtitle: Text(
                '完全开源、免费、无广告、不联网、不收集任何数据。\n'
                '你的 Star 是它继续更新下去的唯一动力。',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(L.tr(ctx, 'licenses')),
              subtitle: const Text('使用的开源组件与协议声明'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LicensesPage()),
              ),
            ),
          ], index: 0),
        ];
      case 'reset':
        return [
          _card(L.tr(ctx, 'reset_defaults'), [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '还原后，所有自定义配置将恢复为默认。本离线版不涉及云同步与账号。',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(L.tr(ctx, 'reset_defaults')),
                        content: Text(L.tr(ctx, 'reset_confirm')),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(L.tr(ctx, 'cancel'))),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(L.tr(ctx, 'confirm'),
                                style: const TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await s.resetToDefaults();
                      _bumpUI();
                      if (mounted) Navigator.pop(context);
                      _toast(L.tr(context, 'reset_defaults'));
                    }
                  },
                  child: Text(L.tr(ctx, 'reset_defaults'),
                      style: const TextStyle(color: Colors.red)),
                ),
              ),
            ),
          ], index: 0),
        ];
      case 'cloudsync':
      case 'cloudbackup':
      case 'localbackup':
        return [
          _card(L.tr(ctx, _titleFor(id)), [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(L.tr(ctx, 'offline_tip'),
                  style: const TextStyle(fontSize: 12.5, height: 1.4)),
            ),
            if (id == 'localbackup')
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.archive),
                    label: const Text('备份整个笔记库'),
                    onPressed: () async {
                      try {
                        final p = await Backup.backupAll();
                        _toast('已备份：$p');
                      } catch (e) {
                        _toast('备份失败：$e');
                      }
                    },
                  ),
                ),
              ),
          ], index: 0),
        ];
      default:
        return [const SizedBox.shrink()];
    }
  }
}

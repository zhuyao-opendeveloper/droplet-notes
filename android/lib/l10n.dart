import 'package:flutter/widgets.dart';

import 'theme.dart';

/// 轻量多语言层（Notein §3.9 Language：跟随 / 英语 / 简体中文 / 繁体中文）。
///
/// 仅覆盖设置 / 首页 / 关键动作的核心字符串；未收录的词条回退到传入的原文（fallback），
/// 因此现有硬编码中文文案在不翻译时仍保持中文，不影响功能。
class L {
  /// language 取值：0 跟随 / 1 英语 / 2 简体 / 3 繁体
  static const Map<String, Map<String, String>> _dict = {
    // —— 设置分组 ——
    'settings_title': {'zh': '设置', 'en': 'Settings', 'zhTW': '設定'},
    'sec_document': {'zh': '我的应用', 'en': 'My App', 'zhTW': '我的應用'},
    'sec_file_settings': {'zh': '文档设置', 'en': 'File Settings', 'zhTW': '文件設定'},
    'sec_page_settings': {'zh': '页面设置', 'en': 'Page Settings', 'zhTW': '頁面設定'},
    'sec_tool_settings': {'zh': '工具设置', 'en': 'Tool Settings', 'zhTW': '工具設定'},
    'sec_guides': {'zh': '辅助线与图形', 'en': 'Guides and Shapes', 'zhTW': '輔助線與圖形'},
    'sec_sync_backup': {'zh': '同步 / 备份', 'en': 'Sync & Backup', 'zhTW': '同步 / 備份'},
    'sec_other': {'zh': '其他', 'en': 'Others', 'zhTW': '其他'},
    'sec_display': {'zh': '显示', 'en': 'Display', 'zhTW': '顯示'},
    'sec_language': {'zh': '语言', 'en': 'Language', 'zhTW': '語言'},
    'sec_gesture': {'zh': '手势设置', 'en': 'Gesture Settings', 'zhTW': '手勢設定'},
    'sec_pen_shortcut': {'zh': '笔快捷键', 'en': 'Pen Shortcut', 'zhTW': '筆快捷鍵'},
    'sec_security': {'zh': '安全', 'en': 'Security', 'zhTW': '安全'},
    'sec_about': {'zh': '关于', 'en': 'About', 'zhTW': '關於'},
    'sec_writing': {'zh': '书写', 'en': 'Writing', 'zhTW': '書寫'},
    'sec_ocr': {'zh': '文字识别（离线 OCR）', 'en': 'Text Recognition (Offline OCR)', 'zhTW': '文字辨識（離線 OCR）'},
    'sec_appearance': {'zh': '外观', 'en': 'Appearance', 'zhTW': '外觀'},

    // —— 通用 ——
    'save': {'zh': '保存', 'en': 'Save', 'zhTW': '儲存'},
    'apply': {'zh': '应用并保存', 'en': 'Apply', 'zhTW': '套用並儲存'},
    'cancel': {'zh': '取消', 'en': 'Cancel', 'zhTW': '取消'},
    'confirm': {'zh': '确认', 'en': 'Confirm', 'zhTW': '確認'},
    'delete': {'zh': '删除', 'en': 'Delete', 'zhTW': '刪除'},
    'ok': {'zh': '确定', 'en': 'OK', 'zhTW': '確定'},
    'close': {'zh': '关闭', 'en': 'Close', 'zhTW': '關閉'},
    'search': {'zh': '搜索', 'en': 'Search', 'zhTW': '搜尋'},
    'settings': {'zh': '设置', 'en': 'Settings', 'zhTW': '設定'},
    'new_note': {'zh': '新建', 'en': 'New', 'zhTW': '新增'},
    'backup': {'zh': '备份', 'en': 'Backup', 'zhTW': '備份'},
    'restore': {'zh': '恢复', 'en': 'Restore', 'zhTW': '復原'},
    'favorite': {'zh': '收藏', 'en': 'Favorites', 'zhTW': '收藏'},
    'tags': {'zh': '标签', 'en': 'Tags', 'zhTW': '標籤'},
    'trash': {'zh': '回收站', 'en': 'Trash', 'zhTW': '資源回收筒'},
    'all': {'zh': '全部', 'en': 'All', 'zhTW': '全部'},
    'home': {'zh': 'Hydro Note', 'en': 'Hydro Note', 'zhTW': 'Hydro Note'},
    'no_notes': {'zh': '还没有笔记，点右下角新建', 'en': 'No notes yet — tap + to create', 'zhTW': '還沒有筆記，點右下角新增'},

    // —— 显示（§3.2）——
    'display_mode': {'zh': '显示模式', 'en': 'Dark Mode Settings', 'zhTW': '顯示模式'},
    'light': {'zh': '浅色', 'en': 'Light', 'zhTW': '淺色'},
    'dark': {'zh': '深色', 'en': 'Dark', 'zhTW': '深色'},
    'auto': {'zh': '自动', 'en': 'Auto', 'zhTW': '自動'},
    'eye_care': {'zh': '护眼', 'en': 'Eye Care', 'zhTW': '護眼'},
    'date_format': {'zh': '日期格式', 'en': 'Date Format', 'zhTW': '日期格式'},
    'keep_screen_on': {'zh': '保持屏幕常亮', 'en': 'Keep Screen ON', 'zhTW': '保持螢幕常亮'},
    'keep_screen_on_sub': {'zh': '开启后保持屏幕常亮', 'en': 'Keep the screen on while the app is open', 'zhTW': '開啟後保持螢幕常亮'},
    'color_inversion': {'zh': '暗黑模式颜色反转', 'en': 'Color Inversion (Dark Mode)', 'zhTW': '深色模式顏色反轉'},

    // —— 手势（§3.3）——
    'two_finger_undo': {'zh': '双指单击撤销', 'en': '2-Finger Tap Undo', 'zhTW': '雙指點擊復原'},
    'three_finger_redo': {'zh': '三指单击重做', 'en': '3-Finger Tap Redo', 'zhTW': '三指點擊重做'},
    'two_finger_swipe_move': {'zh': '双指滑动移动页面', 'en': '2-Finger Swipe to Move Page', 'zhTW': '雙指滑動移動頁面'},
    'double_tap_zoom': {'zh': '单指双击缩放页面', 'en': 'Single-finger Double-tap Zoom', 'zhTW': '單指雙擊縮放頁面'},
    'zoom_disable': {'zh': '禁用', 'en': 'Disabled', 'zhTW': '停用'},
    'zoom_h': {'zh': '横向', 'en': 'Horizontal', 'zhTW': '橫向'},
    'zoom_v': {'zh': '纵向', 'en': 'Vertical', 'zhTW': '縱向'},
    'zoom_both': {'zh': '双向', 'en': 'Both', 'zhTW': '雙向'},

    // —— 页面设置（§3.4）——
    'page_turn_mode': {'zh': '翻页模式', 'en': 'Page Turn Mode', 'zhTW': '翻頁模式'},
    'page_single': {'zh': '单页', 'en': 'Single', 'zhTW': '單頁'},
    'page_continuous': {'zh': '连续滚动', 'en': 'Continuous Scroll', 'zhTW': '連續捲動'},
    'page_add_mode': {'zh': '加页方式', 'en': 'Add Page Mode', 'zhTW': '加頁方式'},
    'page_add_auto': {'zh': '自动加页', 'en': 'Auto', 'zhTW': '自動加頁'},
    'page_add_manual': {'zh': '手动加页', 'en': 'Manual', 'zhTW': '手動加頁'},
    'page_number_pos': {'zh': '页码位置', 'en': 'Page Number Position', 'zhTW': '頁碼位置'},
    'pdf_text_select': {'zh': 'PDF 文字选择', 'en': 'PDF Text Selection', 'zhTW': 'PDF 文字選取'},
    'free_move_page': {'zh': '页面自由移动', 'en': 'Free-Moving Page', 'zhTW': '頁面自由移動'},
    'page_resistance': {'zh': '页面滑动阻力', 'en': 'Page Sliding Resistance', 'zhTW': '頁面滑動阻力'},
    'pen_with_scale': {'zh': '笔画随页面缩放', 'en': 'Pen Follows Scale', 'zhTW': '筆畫隨頁面縮放'},

    // —— 工具设置（§3.5）——
    'pressure_eraser': {'zh': '压感橡皮', 'en': 'Pressure Eraser', 'zhTW': '壓感橡皮'},
    'finger_pressure_eraser': {'zh': '手指压感橡皮', 'en': 'NonStylus Pressure Eraser', 'zhTW': '手指壓感橡皮'},
    'show_undo_redo': {'zh': '显示撤销-重做按钮', 'en': 'Show Undo-Redo Button', 'zhTW': '顯示復原-重做按鈕'},
    'show_layer_op': {'zh': '显示移动图层图标', 'en': 'Show Layer Operation', 'zhTW': '顯示移動圖層圖示'},
    'immersive_toolbar': {'zh': '沉浸式工具栏', 'en': 'Immersive Toolbar', 'zhTW': '沉浸式工具列'},
    'toolbar_style': {'zh': '工具栏样式', 'en': 'Toolbar Style', 'zhTW': '工具列樣式'},
    'traditional': {'zh': '传统', 'en': 'Traditional', 'zhTW': '傳統'},
    'tool_collection': {'zh': '笔盒收藏夹', 'en': 'Tool Collection', 'zhTW': '筆盒收藏夾'},
    'one_stroke_shape': {'zh': '一笔成形', 'en': 'One Stroke to Shape', 'zhTW': '一筆成形'},
    'erase_tape_only': {'zh': '仅擦胶带', 'en': 'Erase Tape Only', 'zhTW': '僅擦膠帶'},
    'select_strokes_only': {'zh': '只选中笔迹', 'en': 'Select Strokes Only', 'zhTW': '只選中筆跡'},

    // —— 辅助线与图形（§3.6）——
    'show_guides': {'zh': '显示辅助线', 'en': 'Show Guides', 'zhTW': '顯示輔助線'},
    'angle_correction': {'zh': '角度矫正', 'en': 'Angle Correction', 'zhTW': '角度矯正'},
    'shape_alignment': {'zh': '图形对齐', 'en': 'Shape Alignment', 'zhTW': '圖形對齊'},
    'ruler_angle': {'zh': '尺子角度', 'en': 'Ruler Angle', 'zhTW': '尺子角度'},
    'fill_shape': {'zh': '图形填充', 'en': 'Fill Shape', 'zhTW': '圖形填充'},
    'fill_opacity': {'zh': '填充不透明度', 'en': 'Fill Opacity', 'zhTW': '填充不透明度'},

    // —— 笔按键（§3.8）——
    'pen_key_action': {'zh': '笔按键功能', 'en': 'Pen Key Action', 'zhTW': '筆按鍵功能'},
    'pen_key_eraser': {'zh': '切换为橡皮', 'en': 'Switch to Eraser', 'zhTW': '切換為橡皮'},
    'pen_key_last': {'zh': '切换上次工具', 'en': 'Last Tool', 'zhTW': '切換上次工具'},
    'pen_key_undo': {'zh': '撤销', 'en': 'Undo', 'zhTW': '復原'},

    // —— 其他 / 同步 / 安全 / 关于 ——
    'pen_shortcut': {'zh': '手写笔快捷键', 'en': 'Stylus Shortcut', 'zhTW': '手寫筆快捷鍵'},
    'auto_update': {'zh': '自动更新', 'en': 'Auto-update', 'zhTW': '自動更新'},
    'reset_defaults': {'zh': '还原初始设置', 'en': 'Reset to Defaults', 'zhTW': '還原初始設定'},
    'reset_confirm': {
      'zh': '确定要还原初始设置吗？还原后，所有自定义配置将恢复为默认。',
      'en': 'Reset all settings to default? Your custom configuration will be lost.',
      'zhTW': '確定要還原初始設定嗎？還原後，所有自訂設定將恢復為預設。'
    },
    'cloud_sync': {'zh': '云同步', 'en': 'Cloud Sync', 'zhTW': '雲同步'},
    'cloud_backup': {'zh': '网盘备份', 'en': 'Cloud Backup', 'zhTW': '網盤備份'},
    'local_backup': {'zh': '本地备份', 'en': 'Local Backup', 'zhTW': '本機備份'},
    'offline_tip': {
      'zh': '本版为离线版，不支持云同步与账号登录。',
      'en': 'This offline edition has no cloud sync or account sign-in.',
      'zhTW': '本版為離線版，不支援雲同步與帳號登入。'
    },
    'app_lock': {'zh': '应用锁', 'en': 'App Lock', 'zhTW': '應用鎖'},
    'set_pin': {'zh': '设置 PIN', 'en': 'Set PIN', 'zhTW': '設定 PIN'},
    'about_app': {'zh': 'Hydro Note', 'en': 'Hydro Note', 'zhTW': 'Hydro Note'},
    'version': {'zh': '离线手写笔记 · 版本 0.1.0', 'en': 'Offline handwriting notes · v0.1.0', 'zhTW': '離線手寫筆記 · 版本 0.1.0'},
    'licenses': {'zh': '开源许可', 'en': 'Licenses', 'zhTW': '開源許可'},

    // —— 首页组织 ——
    'star': {'zh': '星标', 'en': 'Star', 'zhTW': '星標'},
    'add_tag': {'zh': '添加标签', 'en': 'Add Tag', 'zhTW': '新增標籤'},
    'tag_name': {'zh': '标签名称', 'en': 'Tag name', 'zhTW': '標籤名稱'},
    'tag_color': {'zh': '标签颜色', 'en': 'Tag color', 'zhTW': '標籤顏色'},
    'edit_tags': {'zh': '管理标签', 'en': 'Manage Tags', 'zhTW': '管理標籤'},
    'empty_trash': {'zh': '清空回收站', 'en': 'Empty Trash', 'zhTW': '清空資源回收筒'},
    'restore_note': {'zh': '恢复', 'en': 'Restore', 'zhTW': '復原'},
    'permanent_delete': {'zh': '永久删除', 'en': 'Delete Permanently', 'zhTW': '永久刪除'},
    'trashed_time': {'zh': '删除于', 'en': 'Deleted at', 'zhTW': '刪除於'},
    'pages_count': {'zh': '页', 'en': 'pages', 'zhTW': '頁'},
  };

  /// 取翻译；缺词条或缺语言时回退到中文，再回退到 key / fallback。
  static String tr(BuildContext? context, String key, [String? fallback]) {
    final lang = AppSettings.instance.language;
    final localeKey = switch (lang) {
      1 => 'en',
      3 => 'zhTW',
      _ => 'zh', // 0 跟随 / 2 简体 → 用简体中文文案
    };
    final entry = _dict[key];
    if (entry == null) return fallback ?? key;
    return entry[localeKey] ?? entry['zh'] ?? fallback ?? key;
  }

  /// 供 MaterialApp.locale 使用：0 跟随系统返回 null，其余返回对应 Locale。
  static Locale? localeOf() {
    switch (AppSettings.instance.language) {
      case 1:
        return const Locale('en');
      case 2:
        return const Locale('zh', 'CN');
      case 3:
        return const Locale('zh', 'TW');
      default:
        return null;
    }
  }

  static const List<Locale> supportedLocales = [
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
    Locale('en'),
  ];
}

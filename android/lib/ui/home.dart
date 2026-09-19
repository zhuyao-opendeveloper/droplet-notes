import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard：复制仓库地址
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../data/folders.dart';
import '../data/tags.dart';
import '../import/docx_import.dart';
import '../l10n.dart';
import '../models/note.dart';
import '../models/page.dart'; // PageTemplate（新建笔记向导的模板选择）
import '../storage/note_store.dart';
import '../storage/backup.dart';
import '../pdf/import.dart';
import '../theme.dart';
import '../widgets/anim.dart';
import '../ocr/ocr_index.dart';
import 'search.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final NoteStore _store = NoteStore();
  List<Note> _notes = [];
  List<Tag> _tags = [];
  List<Folder> _folders = [];
  List<Note> _trash = [];
  bool _loading = true;
  bool _favOnly = false;
  String? _activeTag;
  bool _showTrash = false;
  // 文件夹筛选：_activeFolder 非空=只看该文件夹；_unfiledOnly=只看未归档；
  // 两者都空=不按文件夹过滤。必须拆成两个字段，"未归档"和"不过滤"都是 null。
  String? _activeFolder;
  bool _unfiledOnly = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    _tags = await TagStore.list();
    _folders = await FolderStore.list();
    if (_showTrash) {
      _trash = await _store.listTrash();
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    final list = await _store.listNotes(
      tagId: _activeTag,
      favoriteOnly: _favOnly,
      folderId: _activeFolder,
      unfiledOnly: _unfiledOnly,
    );
    if (!mounted) return;
    setState(() {
      _notes = list;
      _loading = false;
    });
  }

  Future<void> _newBlank() async {
    // 在哪个文件夹里点新建，新笔记就落在哪个文件夹里（否则建完还得手动移）
    final n = await _store.createBlank(folderId: _activeFolder);
    _open(n.id);
  }

  Future<void> _newWizard() async {
    String title = '';
    double w = 595.0, h = 842.0; // 默认 A4
    PageTemplate tpl = PageTemplate.none;
    int? paper;
    final sizes = {
      'A4 (横向笔记)': (595.0, 842.0),
      'A5 (便携)': (420.0, 595.0),
      '方形 (屏幕)': (720.0, 720.0),
    };
    final papers = {
      '白': null,
      '护眼米': 0xFFF5ECD7,
      '淡绿': 0xFFE8F5E9,
      '淡蓝': 0xFFE3F2FD,
      '淡粉': 0xFFFCE4EC,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(L.tr(ctx, 'new_note')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  decoration: InputDecoration(hintText: L.tr(ctx, 'tag_name')),
                  onChanged: (v) => title = v,
                ),
                const SizedBox(height: 8),
                const Text('纸张尺寸'),
                Wrap(
                  children: sizes.keys
                      .map((k) => Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(k),
                              selected: sizes[k]!.$1 == w,
                              onSelected: (_) => setD(() {
                                w = sizes[k]!.$1;
                                h = sizes[k]!.$2;
                              }),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                const Text('模板'),
                Wrap(
                  children: PageTemplate.values
                      .map((t) => Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(_tplName(t)),
                              selected: tpl == t,
                              onSelected: (_) => setD(() => tpl = t),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                const Text('纸张配色'),
                Wrap(
                  children: papers.keys
                      .map((k) => Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(k),
                              selected: papers[k] == paper,
                              onSelected: (_) => setD(() => paper = papers[k]),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L.tr(ctx, 'cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(L.tr(ctx, 'new_note'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      final n = await _store.createCustom(
        title: title,
        width: w,
        height: h,
        template: tpl,
        paperColor: paper,
        folderId: _activeFolder,
      );
      _open(n.id);
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
        return '康奈尔';
      case PageTemplate.week:
        return '周计划';
      case PageTemplate.month:
        return '月历';
      case PageTemplate.todos:
        return '待办';
      case PageTemplate.checklist:
        return '清单';
      case PageTemplate.math:
        return '方格';
      case PageTemplate.music:
        return '五线谱';
      case PageTemplate.column2:
        return '双栏';
      case PageTemplate.column3:
        return '三栏';
    }
    return t.name;
  }

  Future<void> _importPdf() async {
    const type = XTypeGroup(label: 'PDF', extensions: ['pdf']);
    final file = await openFile(acceptedTypeGroups: [type]);
    if (file == null) return;
    final pages = await PdfImport.importToPages(file.path, title: file.name);
    final note = await _store.createFromPages(pages, file.name);
    _open(note.id);
  }

  /// Word 新建：选一个 .docx，正文提取排版后直接生成一篇新笔记。
  /// （不限定文件选择器的类型过滤——部分安卓 SAF 选择器对 extensions
  /// 过滤兼容差会选不到文件，改为选完在代码里校验扩展名。）
  Future<void> _newFromWord() async {
    final file = await openFile();
    if (file == null) return;
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.doc') && !lower.endsWith('.docx')) {
      _toast('.doc 老格式不支持，请先在 Word 里另存为 .docx');
      return;
    }
    if (!lower.endsWith('.docx')) {
      _toast('请选择 Word 文档（.docx）');
      return;
    }
    try {
      final paras = await DocxImport.paragraphs(file.path);
      if (paras.isEmpty) {
        _toast('未能从该文档提取到文字');
        return;
      }
      final pages = DocxImport.buildPages(paras);
      final title =
          file.name.endsWith('.docx') ? file.name.substring(0, file.name.length - 5) : file.name;
      final note = await _store.createFromPages(pages, title);
      _open(note.id);
    } catch (e) {
      _toast('Word 导入失败：$e');
    }
  }

  /// 新建无边画布（无边笔记）：白纸起步，写到边界外页面自动变长。
  Future<void> _newUnbounded() async {
    final n = await _store.createCustom(
      title: '无边笔记',
      template: PageTemplate.none,
      unbounded: true,
      folderId: _activeFolder,
    );
    _open(n.id);
  }

  void _open(String id) {
    Navigator.pushNamed(context, '/editor', arguments: id)
        .then((_) => _refresh());
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _backup() async {
    try {
      final path = await Backup.backupAll();
      _toast('${L.tr(context, 'backup')}：$path');
    } catch (e) {
      _toast('${L.tr(context, 'backup')}失败：$e');
    }
  }

  Future<void> _restore() async {
    const type = XTypeGroup(label: 'ZIP', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: [type]);
    if (file == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.tr(ctx, 'restore')),
        content: const Text('这将用备份覆盖当前所有笔记，确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.tr(ctx, 'cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('覆盖恢复')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Backup.restoreAll(file.path);
      await _refresh();
      _toast(L.tr(context, 'restore'));
    } catch (e) {
      _toast('恢复失败：$e');
    }
  }

  Future<void> _toggleFav(Note n) async {
    final updated = n.copyWith(favorite: !n.favorite);
    await _store.saveNote(updated);
    _refresh();
  }

  Future<void> _toTrash(Note n) async {
    await _store.trashNote(n.id);
    await _refresh();
    _toast('${L.tr(context, 'trash')}：${n.title}');
  }

  Future<void> _restoreFromTrash(Note n) async {
    await _store.restoreNote(n.id);
    await _refresh();
  }

  Future<void> _permDelete(Note n) async {
    await _store.deleteNote(n.id);
    await OcrIndex.removeNote(n.id);
    await _refresh();
  }

  /// 开源仓库 + 求 Star。
  ///
  /// 本作免费、无广告、不联网、不收集任何数据；没有付费墙也没有遥测，
  /// 唯一能支持它继续更新下去的就是仓库的 Star。
  Future<void> _showRepoDialog() async {
    await showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Hydro Note 完全开源'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('免费、无广告、不联网、不收集任何数据。'),
            SizedBox(height: 10),
            Text('如果它对你有用，欢迎到仓库点个 Star —— 这是它继续更新下去的唯一动力。'),
            SizedBox(height: 12),
            SelectableText(kRepoUrl, style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('知道了')),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: kRepoUrl));
              if (!mounted) return;
              Navigator.pop(d);
              _toast('仓库地址已复制');
            },
            child: const Text('复制地址'),
          ),
        ],
      ),
    );
  }

  Future<void> _emptyTrash() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.tr(ctx, 'empty_trash')),
        content: const Text('将永久删除回收站中的全部笔记，且无法恢复。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.tr(ctx, 'cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.tr(ctx, 'empty_trash'),
                style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _store.emptyTrash();
      await _refresh();
      _toast(L.tr(context, 'empty_trash'));
    }
  }

  /// 标签编辑底部面板：勾选/取消标签，并支持新建标签（名称 + 颜色）。
  Future<void> _openTagEditor(Note n) async {
    List<Tag> tags = await TagStore.list();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L.tr(ctx, 'tags'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              ...tags.map((t) => CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Color(TagStore.palette[t.color]),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(t.name),
                      ],
                    ),
                    value: n.tags.contains(t.id),
                    onChanged: (sel) async {
                      final set = {...n.tags};
                      if (sel == true) {
                        set.add(t.id);
                      } else {
                        set.remove(t.id);
                      }
                      final updated = n.copyWith(tags: set.toList());
                      await _store.saveNote(updated);
                      n = updated;
                      setD(() {});
                    },
                  )),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(L.tr(ctx, 'add_tag')),
                onTap: () async {
                  final newTag = await _createTagDialog(ctx);
                  if (newTag != null) {
                    tags = await TagStore.list();
                    final updated = n.copyWith(tags: [...n.tags, newTag.id]);
                    await _store.saveNote(updated);
                    n = updated;
                    setD(() {});
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
    _refresh();
  }

  /// 新建标签：输入名称 + 选择 8 色之一。
  Future<Tag?> _createTagDialog(BuildContext ctx) async {
    String name = '';
    int color = 0;
    return showDialog<Tag?>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setD) => AlertDialog(
          title: Text(L.tr(dctx, 'add_tag')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: InputDecoration(hintText: L.tr(dctx, 'tag_name')),
                onChanged: (v) => name = v,
              ),
              const SizedBox(height: 10),
              Text(L.tr(dctx, 'tag_color')),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: List.generate(TagStore.palette.length, (i) {
                  final selected = color == i;
                  return GestureDetector(
                    onTap: () => setD(() => color = i),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Color(TagStore.palette[i]),
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: Colors.black, width: 3)
                            : null,
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, null),
                child: Text(L.tr(dctx, 'cancel'))),
            TextButton(
              onPressed: () async {
                final t = await TagStore.create(
                    name.isEmpty ? TagStore.paletteNames[color] : name, color);
                if (!mounted) return;
                Navigator.pop(dctx, t);
              },
              child: Text(L.tr(dctx, 'ok'))),
          ],
        ),
      ),
    );
  }

  Widget _tagChips(Note n) {
    if (n.tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: n.tags.map((id) {
        final t = TagStore.byId(id);
        if (t == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Color(TagStore.palette[t.color]).withOpacity(0.18),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            t.name,
            style: TextStyle(
                fontSize: 11, color: Color(TagStore.palette[t.color])),
          ),
        );
      }).toList(),
    );
  }

  Widget _noteCard(Note n) {
    final paper = n.pages.isNotEmpty ? n.pages.first.paperColor : null;
    final eye = AppSettings.instance.themeMode == AppThemeMode.eyeCare;
    final base = paper != null
        ? Color(paper)
        : (eye ? const Color(0xFFF5ECD7) : Colors.white);
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: PressScale(
        scale: 0.97,
        child: InkWell(
          onTap: () => _open(n.id),
          onLongPress: () => _openTagEditor(n),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 92,
                width: double.infinity,
                color: base,
                child: Center(
                  child: flu(FluentIcons.book_24_regular, FluentIcons.book_24_filled),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(n.title,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (n.favorite)
                          Icon(FluentIcons.star_24_filled,
                              size: 16, color: Colors.amber),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${n.pages.length} ${L.tr(context, 'pages_count')} · ${_fmt(n.updatedAt)}',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    _tagChips(n),
                    // 归属文件夹：在「全部」视图下才知道这本笔记放哪儿了
                    if (n.folderId != null)
                      Builder(builder: (ctx) {
                        final f = FolderStore.byId(n.folderId);
                        if (f == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.folder,
                                  size: 13, color: Color(TagStore.palette[f.color])),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(f.name,
                                    style: Theme.of(context).textTheme.bodySmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        );
                      }),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        PressScale(
                          child: IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 38, height: 38),
                            icon: flu(FluentIcons.star_24_regular,
                                FluentIcons.star_24_filled),
                            color: n.favorite ? Colors.amber : null,
                            tooltip: L.tr(context, 'star'),
                            onPressed: () => _toggleFav(n),
                          ),
                        ),
                        PressScale(
                          child: IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 38, height: 38),
                            icon: flu(FluentIcons.tag_24_regular,
                                FluentIcons.tag_24_filled),
                            tooltip: L.tr(context, 'tags'),
                            onPressed: () => _openTagEditor(n),
                          ),
                        ),
                        PressScale(
                          child: IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 38, height: 38),
                            // 两参数都传 regular：filled 版图标名不确认存在于
                            // 当前锁定的 fluentui_system_icons 版本，不值得为图标
                            // 样式赌一次编译。（项目里 folder_24_regular 已在使用）
                            icon: flu(FluentIcons.folder_24_regular,
                                FluentIcons.folder_24_regular),
                            tooltip: '移动到文件夹',
                            onPressed: () => _moveNoteDialog(n),
                          ),
                        ),
                        PressScale(
                          child: IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 38, height: 38),
                            icon: flu(FluentIcons.delete_24_regular,
                                FluentIcons.delete_24_filled),
                            tooltip: L.tr(context, 'trash'),
                            onPressed: () => _toTrash(n),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trashCard(Note n) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: flu(FluentIcons.book_24_regular, FluentIcons.book_24_filled),
        title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${L.tr(context, 'trashed_time')} ${_fmt(n.trashedAt ?? 0)}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => _restoreFromTrash(n),
              child: Text(L.tr(context, 'restore_note')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => _permDelete(n),
              child: Text(L.tr(context, 'permanent_delete')),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final p = (int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// 顶部筛选条：全部 / 收藏 + 各标签色块。
  Widget _filterRow() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: Text(L.tr(context, 'all')),
              selected: !_favOnly && _activeTag == null,
              onSelected: (_) => setState(() {
                _favOnly = false;
                _activeTag = null;
                _refresh();
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: Text(L.tr(context, 'favorite')),
              selected: _favOnly,
              onSelected: (_) => setState(() {
                _favOnly = !_favOnly;
                _activeTag = null;
                _refresh();
              }),
            ),
          ),
          ..._tags.map((t) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  avatar: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: Color(TagStore.palette[t.color]),
                      shape: BoxShape.circle,
                    ),
                  ),
                  label: Text(t.name),
                  selected: _activeTag == t.id,
                  onSelected: (_) => setState(() {
                    _activeTag = _activeTag == t.id ? null : t.id;
                    _favOnly = false;
                    _refresh();
                  }),
                ),
              )),
        ],
      ),
    );
  }

  /// 空列表提示：说清楚是因为筛选条件为空，还是真的没笔记 ——
  /// 只写「还没有笔记」会让人以为笔记丢了。
  String _emptyHint() {
    if (_activeFolder != null) {
      return '「${FolderStore.byId(_activeFolder)?.name ?? '该文件夹'}」里还没有笔记';
    }
    if (_unfiledOnly) return '没有未归档的笔记';
    if (_activeTag != null) {
      final t = _tags.where((e) => e.id == _activeTag);
      return '没有带「${t.isEmpty ? '' : t.first.name}」标签的笔记';
    }
    if (_favOnly) return '还没有收藏的笔记';
    return '还没有笔记，点右下角新建';
  }

  // ---------- 文件夹 ----------

  /// 文件夹行：全部 / 未归档 / 各文件夹 / 新建。长按文件夹可重命名改色删除。
  Widget _folderRow() {
    final noneActive = _activeFolder == null && !_unfiledOnly;
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _fChip(
            icon: Icons.inbox,
            label: '全部',
            selected: noneActive,
            onTap: () => setState(() {
              _activeFolder = null;
              _unfiledOnly = false;
              _refresh();
            }),
          ),
          _fChip(
            icon: FluentIcons.folder_24_regular,
            label: '未归档',
            selected: _unfiledOnly,
            onTap: () => setState(() {
              _activeFolder = null;
              _unfiledOnly = !_unfiledOnly;
              _refresh();
            }),
          ),
          ..._folders.map((f) => _fChip(
                icon: FluentIcons.folder_24_regular,
                iconColor: Color(TagStore.palette[f.color]),
                label: f.name,
                selected: _activeFolder == f.id,
                onTap: () => setState(() {
                  _activeFolder = _activeFolder == f.id ? null : f.id;
                  _unfiledOnly = false;
                  _refresh();
                }),
                onLongPress: () => _folderMenu(f),
              )),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: ActionChip(
              avatar: const Icon(Icons.create_new_folder, size: 16),
              label: const Text('新建文件夹'),
              onPressed: _newFolderDialog,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fChip({
    required IconData icon,
    required String label,
    Color? iconColor,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: FilterChip(
          avatar: Icon(icon, size: 16, color: iconColor),
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }

  /// 新建文件夹：名称 + 8 色之一（与标签共用调色板）。
  Future<void> _newFolderDialog() async {
    final ctrl = TextEditingController();
    var color = 4;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('新建文件夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '文件夹名称'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < TagStore.palette.length; i++)
                    GestureDetector(
                      onTap: () => setD(() => color = i),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Color(TagStore.palette[i]),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == i ? Colors.black87 : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('创建')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      _toast('请输入文件夹名称');
      return;
    }
    await FolderStore.create(name, color);
    if (!mounted) return;
    await _refresh();
  }

  /// 文件夹长按菜单：重命名 / 更改颜色 / 删除。
  Future<void> _folderMenu(Folder f) async {
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(f.name),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'rename'),
              child: const Text('重命名')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'color'),
              child: const Text('更改颜色')),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除文件夹',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (act == null) return;
    if (act == 'rename') {
      final ctrl = TextEditingController(text: f.name);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重命名文件夹'),
          content: TextField(controller: ctrl, autofocus: true),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      );
      final nm = ctrl.text.trim();
      if (ok == true && nm.isNotEmpty) {
        await FolderStore.rename(f.id, nm);
        if (!mounted) return;
        await _refresh();
      }
      return;
    }
    if (act == 'color') {
      var color = f.color;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('文件夹颜色'),
            content: Wrap(
              spacing: 10,
              children: [
                for (var i = 0; i < TagStore.palette.length; i++)
                  GestureDetector(
                    onTap: () => setD(() => color = i),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(TagStore.palette[i]),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == i ? Colors.black87 : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存')),
            ],
          ),
        ),
      );
      if (ok == true) {
        await FolderStore.setColor(f.id, color);
        if (!mounted) return;
        await _refresh();
      }
      return;
    }
    // 删除文件夹：只删文件夹本身，里面的笔记移回「未归档」——
    // 用户删的是容器不是内容，跟着一起删掉笔记是不可接受的。
    final inside = await _store.listNotes(folderId: f.id);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件夹'),
        content: Text(inside.isEmpty
            ? '确定删除「${f.name}」吗？'
            : '「${f.name}」里有 ${inside.length} 本笔记。删除文件夹不会删除笔记，它们会被移回「未归档」。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final n in inside) {
      final full = await _store.loadNote(n.id);
      await _store.saveNote(full.copyWith(clearFolder: true));
    }
    await FolderStore.remove(f.id);
    if (_activeFolder == f.id) _activeFolder = null;
    if (!mounted) return;
    await _refresh();
  }

  /// 把笔记移动到文件夹；[folderId] 为 null 表示移出（回到未归档）。
  Future<void> _moveNote(Note n, String? folderId) async {
    final full = await _store.loadNote(n.id);
    await _store.saveNote(
        full.copyWith(clearFolder: folderId == null, folderId: folderId));
    if (!mounted) return;
    final name = FolderStore.byId(folderId)?.name;
    _toast(folderId == null ? '已移出文件夹' : '已移动到「$name」');
    await _refresh();
  }

  /// 选择目标文件夹（'' 代表「未归档」，null 代表用户取消）。
  Future<void> _moveNoteDialog(Note n) async {
    final folders = await FolderStore.list();
    if (!mounted) return;
    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移动到文件夹'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Row(
              children: [
                const Icon(Icons.folder_off, size: 20, color: Colors.grey),
                const SizedBox(width: 10),
                const Expanded(child: Text('未归档')),
                if (n.folderId == null) const Icon(Icons.check, size: 18),
              ],
            ),
          ),
          ...folders.map((f) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f.id),
                child: Row(
                  children: [
                    Icon(Icons.folder,
                        size: 20, color: Color(TagStore.palette[f.color])),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(f.name, overflow: TextOverflow.ellipsis),
                    ),
                    if (n.folderId == f.id) const Icon(Icons.check, size: 18),
                  ],
                ),
              )),
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx);
              _newFolderDialog();
            },
            child: const Text('+ 新建文件夹'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await _moveNote(n, picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showTrash ? L.tr(context, 'trash') : L.tr(context, 'home')),
        actions: _showTrash
            ? [
                PressScale(
                  child: TextButton.icon(
                    onPressed: _emptyTrash,
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    label: Text(L.tr(context, 'empty_trash'),
                        style: const TextStyle(color: Colors.red)),
                  ),
                ),
                PressScale(
                  child: IconButton(
                    icon: flu(FluentIcons.arrow_left_24_regular,
                        FluentIcons.arrow_left_24_filled),
                    tooltip: L.tr(context, 'close'),
                    onPressed: () => setState(() {
                      _showTrash = false;
                      _refresh();
                    }),
                  ),
                ),
              ]
            : [
                PressScale(
                  child: IconButton(
                    icon: flu(FluentIcons.search_24_regular,
                        FluentIcons.search_24_filled),
                    tooltip: L.tr(context, 'search'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SearchPage()),
                    ).then((_) => _refresh()),
                  ),
                ),
                PressScale(
                  child: IconButton(
                    icon: flu(FluentIcons.arrow_download_24_regular,
                        FluentIcons.arrow_download_24_filled),
                    tooltip: L.tr(context, 'backup'),
                    onPressed: _backup,
                  ),
                ),
                PressScale(
                  child: IconButton(
                    icon: flu(FluentIcons.arrow_upload_24_regular,
                        FluentIcons.arrow_upload_24_filled),
                    tooltip: L.tr(context, 'restore'),
                    onPressed: _restore,
                  ),
                ),
                PressScale(
                  child: IconButton(
                    icon: flu(FluentIcons.delete_24_regular,
                        FluentIcons.delete_24_filled),
                    tooltip: L.tr(context, 'trash'),
                    onPressed: () => setState(() {
                      _showTrash = true;
                      _refresh();
                    }),
                  ),
                ),
                PressScale(
                  child: IconButton(
                    icon: flu(FluentIcons.settings_24_regular,
                        FluentIcons.settings_24_filled),
                    tooltip: L.tr(context, 'settings'),
                    onPressed: () => Navigator.pushNamed(context, '/settings')
                        .then((_) => setState(() {})),
                  ),
                ),
                PressScale(
                  child: IconButton(
                    icon: const Icon(Icons.star_border),
                    tooltip: '给个 Star',
                    onPressed: _showRepoDialog,
                  ),
                ),
              ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _showTrash
              ? (_trash.isEmpty
                  ? FadeSlideIn(
                      child: Center(child: Text(L.tr(context, 'trash'))))
                  : ListView.builder(
                      itemCount: _trash.length,
                      itemBuilder: (_, i) => FadeSlideIn(
                        key: ValueKey(_trash[i].id),
                        delay: AppAnim.stagger * (i % 12),
                        child: _trashCard(_trash[i]),
                      ),
                    ))
              : Column(
                  children: [
                    _folderRow(),
                    _filterRow(),
                    Expanded(
                      child: _notes.isEmpty
                          ? FadeSlideIn(
                              child: Center(child: Text(_emptyHint())))
                          : Padding(
                              padding: const EdgeInsets.all(12),
                              child: GridView.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 220,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 0.82,
                                ),
                                itemCount: _notes.length,
                                itemBuilder: (_, i) => FadeSlideIn(
                                  key: ValueKey(_notes[i].id),
                                  delay: AppAnim.stagger * (i % 12),
                                  child: _noteCard(_notes[i]),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
      floatingActionButton: PressScale(
        scale: 0.92,
        child: FloatingActionButton(
          onPressed: () async {
            final choice = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: Text(L.tr(ctx, 'new_note')),
                children: [
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'wizard'),
                    child: Text(L.tr(ctx, 'new_note')),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'blank'),
                    child: const Text('空白笔记'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'unbounded'),
                    child: const Text('新建无边画布'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'pdf'),
                    child: const Text('从 PDF 导入'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'word'),
                    child: const Text('Word 新建'),
                  ),
                ],
              ),
            );
            if (choice == 'wizard') _newWizard();
            if (choice == 'blank') _newBlank();
            if (choice == 'unbounded') _newUnbounded();
            if (choice == 'pdf') _importPdf();
            if (choice == 'word') _newFromWord();
          },
          child: flu(FluentIcons.add_24_regular, FluentIcons.add_24_filled),
        ),
      ),
    );
  }
}

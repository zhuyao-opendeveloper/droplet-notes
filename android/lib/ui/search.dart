import 'dart:async';

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../ocr/ocr_index.dart';
import '../storage/note_store.dart';
import '../widgets/anim.dart';
import 'editor.dart';

/// 全文搜索：笔记标题 + 已建索引页的 OCR 文字。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final NoteStore _store = NoteStore();
  final TextEditingController _ctl = TextEditingController();
  List<Note> _notes = [];
  List<OcrHit> _hits = [];
  int _indexedPages = 0;
  bool _loading = true;
  Timer? _debounce;
  int _seq = 0; // 搜索请求序号：慢的旧请求返回后不能覆盖新结果

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final notes = await _store.listNotes();
    final cnt = await OcrIndex.indexedPageCount();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _indexedPages = cnt;
      _loading = false;
    });
  }

  /// 输入防抖：每敲一个字符就遍历全部索引搜一遍，快速输入时会明显卡顿，
  /// 还会并发跑很多次搜索。
  void _onQueryChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(v));
  }

  Future<void> _run(String q) async {
    final seq = ++_seq;
    final hits = await OcrIndex.search(q, _notes);
    // 序号不符说明这是被后续输入取代的旧请求，丢弃，否则结果会乱序覆盖
    if (!mounted || seq != _seq) return;
    setState(() => _hits = hits);
  }

  void _open(OcrHit h) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditorPage(h.noteId, initialPage: h.pageIndex),
      ),
    ).then((_) => _init());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '搜索标题或页面文字…',
          ),
          onChanged: _onQueryChanged,
        ),
        actions: [
          PressScale(
            child: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _debounce?.cancel();
                _seq++; // 让还在跑的搜索结果作废
                _ctl.clear();
                setState(() => _hits = []);
              },
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '已索引 $_indexedPages 页。页面文字需先在编辑器里「识别文字」'
                          '或在设置里批量建索引。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _ctl.text.trim().isEmpty
                      ? const FadeSlideIn(
                          child: Center(child: Text('输入关键词开始搜索')))
                      : _hits.isEmpty
                          ? const FadeSlideIn(
                              child: Center(child: Text('没有匹配结果')))
                          : ListView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: _hits.length,
                              itemBuilder: (_, i) => FadeSlideIn(
                                key: ValueKey('${_hits[i].noteId}-${_hits[i].pageIndex}'),
                                delay: AppAnim.stagger * (i % 10), // 结果逐条浮现
                                duration: AppAnim.fast,
                                child: _hitCard(_hits[i]),
                              ),
                            ),
                ),
              ],
            ),
    );
  }

  Widget _hitCard(OcrHit h) => Card(
        elevation: 1,
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ListTile(
          leading: Icon(h.titleMatch ? Icons.title : Icons.text_snippet_outlined),
          title: Text(h.noteTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            h.titleMatch ? h.snippet : '第 ${h.pageIndex + 1} 页 · ${h.snippet}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(h),
        ),
      );
}

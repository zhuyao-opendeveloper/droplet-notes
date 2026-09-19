import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ocr/ocr_service.dart';
import '../ocr/ocr_index.dart';
import '../widgets/anim.dart';

/// 识别结果页：可编辑校正、复制、写入搜索索引、插入回页面为文本框。
///
/// 关闭时若点了「插入为文本框」，通过 Navigator.pop 返回文本字符串。
class OcrPage extends StatefulWidget {
  final OcrResult result;
  final String noteId;
  final int pageIndex;

  const OcrPage({
    super.key,
    required this.result,
    required this.noteId,
    required this.pageIndex,
  });

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.result.text);
  bool _indexed = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _saveToIndex() async {
    await OcrIndex.putPage(widget.noteId, widget.pageIndex, _ctl.text);
    if (!mounted) return;
    setState(() => _indexed = true);
    _toast('已写入搜索索引，可在首页搜索到这页');
  }

  Widget _card(
          {required String title, required List<Widget> children, int index = 0}) =>
      FadeSlideIn(
        delay: AppAnim.stagger * index, // 结果页各卡片错落浮现
        child: Card(
          elevation: 1,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    )),
              ),
              ...children,
              const SizedBox(height: 6),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('识别结果'),
        actions: [
          PressScale(
            child: IconButton(
              tooltip: '复制全部',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _ctl.text));
                _toast('已复制到剪贴板');
              },
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          _card(
            title: '统计',
            children: [
              ListTile(
                dense: true,
                title: Text('第 ${widget.pageIndex + 1} 页 · '
                    '${r.charCount} 字 · ${r.blocks.length} 个文本块'),
                subtitle: Text(_indexed ? '已加入搜索索引' : '尚未加入搜索索引'),
              ),
            ],
          ),
          _card(
            index: 1,
            title: '文字（可直接校正）',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: _ctl,
                  maxLines: null,
                  minLines: 8,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '没识别到文字',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _saveToIndex,
                      icon: const Icon(Icons.search),
                      label: const Text('存入搜索索引'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _ctl.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(context, _ctl.text),
                      icon: const Icon(Icons.text_fields),
                      label: const Text('插入为文本框'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (r.blocks.length > 1)
            _card(
              index: 2,
              title: '分块结果',
              children: [
                for (final e in r.blocks.asMap().entries)
                  FadeSlideIn(
                    delay: AppAnim.stagger * (e.key % 8),
                    duration: AppAnim.fast,
                    child: Builder(
                      builder: (_) {
                        final b = e.value;
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.short_text, size: 18),
                          title:
                              Text(b.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                          trailing: PressScale(
                            child: IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: b.text));
                                _toast('已复制该块');
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          _card(
            index: 3,
            title: '关于识别效果',
            children: const [
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(
                  '引擎为完全离线的 ML Kit Text Recognition v2（模型随应用打包，'
                  '不联网、不依赖 Google 服务）。\n\n'
                  '• 印刷体（PDF 扫描页、截图、拍照插图）识别率最高\n'
                  '• 工整手写可用，连笔／草书中文效果较差\n'
                  '• 识别不准时可在上面直接改，再存入索引',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

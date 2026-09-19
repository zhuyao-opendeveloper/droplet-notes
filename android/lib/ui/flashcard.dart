import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../models/flashcard.dart';
import '../storage/flashcard_store.dart';
import '../theme.dart';
import '../widgets/anim.dart';

/// 闪卡：卡片管理 + SM-2 间隔重复学习。纯本地。
class FlashcardPage extends StatefulWidget {
  final String noteId;
  const FlashcardPage(this.noteId, {super.key});

  @override
  State<FlashcardPage> createState() => _FlashcardPageState();
}

class _FlashcardPageState extends State<FlashcardPage> {
  FlashCardDeck? _deck;
  bool _studying = false;
  int _idx = 0;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await FlashCardStore.load(widget.noteId);
    if (!mounted) return;
    setState(() => _deck = d);
  }

  Future<void> _save() async {
    if (_deck != null) await FlashCardStore.save(_deck!);
  }

  void _addCard() async {
    final front = TextEditingController();
    final back = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建闪卡'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: front,
              maxLines: 3,
              decoration: const InputDecoration(hintText: '正面（问题）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: back,
              maxLines: 3,
              decoration: const InputDecoration(hintText: '背面（答案）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok == true && front.text.isNotEmpty && _deck != null) {
      final cards = List<FlashCard>.from(_deck!.cards)
        ..add(FlashCard(
          id: FlashCardStore.newId(),
          front: front.text,
          back: back.text,
        ));
      setState(() => _deck = _deck!.copyWith(cards: cards));
      await _save();
    }
  }

  void _deleteCard(String id) async {
    if (_deck == null) return;
    final cards = _deck!.cards.where((c) => c.id != id).toList();
    setState(() => _deck = _deck!.copyWith(cards: cards));
    await _save();
  }

  void _startStudy() {
    if (_deck == null || _deck!.cards.isEmpty) return;
    setState(() {
      _studying = true;
      _idx = 0;
      _revealed = false;
    });
  }

  void _grade(int quality) {
    if (_deck == null) return;
    final card = _deck!.cards[_idx];
    scheduleSm2(card, quality);
    _save();
    if (_idx < _deck!.cards.length - 1) {
      setState(() {
        _idx++;
        _revealed = false;
      });
    } else {
      setState(() => _studying = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('本轮学习完成')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_deck == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_studying && _deck!.cards.isNotEmpty) {
      final card = _deck!.cards[_idx];
      return Scaffold(
        appBar: AppBar(
          title: Text('学习 ${_idx + 1}/${_deck!.cards.length}'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _studying = false),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _revealed = true),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: AnimatedScale(
                      scale: _revealed ? 1.0 : 0.97,
                      duration: AppAnim.normal,
                      curve: AppAnim.spring,
                      child: SwitchFade(
                        axis: Axis.vertical,
                        child: Text(
                          _revealed ? card.back : card.front,
                          key: ValueKey(_revealed), // 正反面切换时交叉淡入
                          style: const TextStyle(fontSize: 26),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_revealed)
              FadeSlideIn(
                duration: AppAnim.normal, // 显示答案后评分按钮滑入
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      _gradeBtn('重来', Colors.red, () => _grade(2)),
                      _gradeBtn('困难', Colors.orange, () => _grade(3)),
                      _gradeBtn('良好', Colors.blue, () => _grade(4)),
                      _gradeBtn('简单', Colors.green, () => _grade(5)),
                    ],
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('点按卡片显示答案', textAlign: TextAlign.center),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('闪卡（${_deck!.cards.length}）'),
        actions: [
          IconButton(
            icon: flu(FluentIcons.play_24_regular, FluentIcons.play_24_filled),
            tooltip: '开始学习',
            onPressed: _deck!.cards.isEmpty ? null : _startStudy,
          ),
        ],
      ),
      body: _deck!.cards.isEmpty
          ? const Center(child: Text('还没有闪卡，点右下角添加'))
          : ListView.builder(
              itemCount: _deck!.cards.length,
              itemBuilder: (_, i) {
                final c = _deck!.cards[i];
                return FadeSlideIn(
                  key: ValueKey(c.id),
                  delay: AppAnim.stagger * (i % 10),
                  duration: AppAnim.fast,
                  child: ListTile(
                    title: Text(c.front),
                    subtitle: Text(c.back),
                    trailing: PressScale(
                      child: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteCard(c.id),
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: PressScale(
        scale: 0.92,
        child: FloatingActionButton(
          onPressed: _addCard,
          child: flu(FluentIcons.add_24_regular, FluentIcons.add_24_filled),
        ),
      ),
    );
  }

  Widget _gradeBtn(String label, Color c, VoidCallback on) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: PressScale(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: c),
              onPressed: on,
              child: Text(label),
            ),
          ),
        ),
      );
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
// 本项目有自己的 models/page.dart（笔记页），与 Flutter 的 Route Page 撞名，需 hide
import 'package:flutter/material.dart' hide Page;

import '../engine/freehand.dart';
import '../models/note.dart';
import '../models/stroke.dart';
import '../models/tool.dart';
import '../models/page.dart';
import '../theme.dart';

/// 音频笔记录放：播放录音，并按笔迹时间戳 t 顺序逐笔显现手写内容。
class AudioPlaybackPage extends StatefulWidget {
  final Note note;
  const AudioPlaybackPage(this.note, {super.key});

  @override
  State<AudioPlaybackPage> createState() => _AudioPlaybackPageState();
}

class _AudioPlaybackPageState extends State<AudioPlaybackPage> {
  final _player = AudioPlayer();
  int _posMs = 0;
  int _page = 0;
  Timer? _tick;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    if (widget.note.audioPath != null) {
      _player.play(DeviceFileSource(widget.note.audioPath!));
      _playing = true;
      _tick = Timer.periodic(const Duration(milliseconds: 50), (_) => _poll());
      _player.onPlayerComplete.listen((_) => setState(() => _playing = false));
    }
  }

  Future<void> _poll() async {
    final p = await _player.getCurrentPosition();
    if (p != null && mounted) setState(() => _posMs = p.inMilliseconds);
  }

  void _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.resume();
    }
    if (!mounted) return;
    setState(() => _playing = !_playing);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _player.dispose();
    super.dispose();
  }

  List<Stroke> _revealed(Page pg) =>
      pg.strokes.where((s) => s.t == null || s.t! <= _posMs).toList();

  @override
  Widget build(BuildContext context) {
    final pg = widget.note.pages[_page];
    final revealed = _revealed(pg);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.note.title} · 回放 ${_page + 1}/${widget.note.pages.length}'),
        actions: [
          IconButton(
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: _toggle,
          ),
          if (widget.note.pages.length > 1) ...[
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _page > 0 ? () => setState(() => _page--) : null,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _page < widget.note.pages.length - 1
                  ? () => setState(() => _page++)
                  : null,
            ),
          ],
        ],
      ),
      body: Center(
        child: AspectRatio(
          aspectRatio: pg.width / pg.height,
          child: CustomPaint(
            size: Size(pg.width, pg.height),
            painter: _ReplayPainter(pg, revealed),
          ),
        ),
      ),
    );
  }
}

class _ReplayPainter extends CustomPainter {
  final Page page;
  final List<Stroke> revealed;
  _ReplayPainter(this.page, this.revealed);

  @override
  void paint(Canvas canvas, Size size) {
    final base =
        AppSettings.instance.themeMode == AppThemeMode.eyeCare
            ? const Color(0xFFF5ECD7)
            : Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = base);
    for (final s in revealed) {
      final path = Freehand.buildPath(s);
      final paint = Paint()
        ..color = Color(s.color).withOpacity(s.opacity)
        ..strokeWidth = s.size * (size.width / page.width)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (s.isShape) {
        paint.style = PaintingStyle.stroke;
        canvas.drawPath(path, paint);
      } else {
        paint.style = PaintingStyle.fill;
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ReplayPainter old) => true;
}

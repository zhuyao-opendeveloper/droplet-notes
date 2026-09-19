import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/anim.dart';

/// 应用锁密码输入屏。校验通过后回调 onUnlock。
class PinScreen extends StatefulWidget {
  final VoidCallback onUnlock;
  const PinScreen({super.key, required this.onUnlock});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen>
    with SingleTickerProviderStateMixin {
  final List<int> _buf = [];
  String _err = '';
  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  /// 密码错误时左右抖动一下，比单纯红字更直观
  void _playShake() => _shake.forward(from: 0);

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _tap(int d) {
    if (_buf.length < 4) _buf.add(d);
    if (_buf.length == 4) {
      final entered = _buf.join();
      if (entered == AppSettings.instance.lockPin) {
        widget.onUnlock();
        return;
      }
      _err = '密码错误，请重试';
      _buf.clear();
      _playShake();
    }
    setState(() {});
  }

  void _del() {
    if (_buf.isNotEmpty) {
      _buf.removeLast();
      _err = '';
      setState(() {});
    }
  }

  Widget _key(String label, VoidCallback on) => PressScale(
        scale: 0.85,
        onTap: on,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Center(
              child: Text(label, style: const TextStyle(fontSize: 24))),
        ),
      );

  List<Widget> _keypad() {
    final rows = <Widget>[];
    for (var r = 0; r < 4; r++) {
      final items = <Widget>[];
      for (var c = 0; c < 3; c++) {
        if (r == 3 && c == 0) {
          items.add(_key('⌫', _del));
        } else if (r == 3 && c == 1) {
          items.add(_key('0', () => _tap(0)));
        } else if (r == 3 && c == 2) {
          items.add(const SizedBox(width: 64, height: 64));
        } else {
          final n = r * 3 + c + 1;
          items.add(_key('$n', () => _tap(n)));
        }
      }
      rows.add(Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: items));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FadeSlideIn(
            duration: AppAnim.slow,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('输入应用锁密码', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 24),
              AnimatedBuilder(
                animation: _shake,
                builder: (ctx, child) {
                  // 0~1 衰减正弦：左右各抖 6dp
                  final t = _shake.value;
                  final dx = t == 0 || t == 1
                      ? 0.0
                      : 6 * (1 - t) * math.sin(t * 3 * math.pi) * 2;
                  return Transform.translate(offset: Offset(dx, 0), child: child);
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    4,
                    (i) => AnimatedContainer(
                      duration: AppAnim.fast,
                      curve: AppAnim.spring,
                      width: i < _buf.length ? 20 : 16,
                      height: i < _buf.length ? 20 : 16,
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _buf.length
                            ? Colors.blue
                            : Colors.grey.shade300,
                      ),
                    ),
                  ),
                ),
              ),
              if (_err.isNotEmpty)
                FadeSlideIn(
                  duration: AppAnim.fast,
                  offset: const Offset(0, 0.3),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_err, style: const TextStyle(color: Colors.red)),
                  ),
                ),
              const SizedBox(height: 24),
              ..._keypad(),
            ],
          ),
          ),
        ),
      );
}

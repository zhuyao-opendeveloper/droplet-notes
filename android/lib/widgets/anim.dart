import 'package:flutter/material.dart';

/// 全 App 统一的动画参数与通用过渡组件。
///
/// 收口目的：所有界面的动效共用同一套时长/曲线，避免各页面手写魔法数字；
/// 同时提供几个可复用的过渡 Widget（淡入上滑、按压缩放、循环脉冲、
/// 内容切换交叉淡入、底部面板），新界面接入动画只需包一层。
class AppAnim {
  AppAnim._();

  /// 轻快反馈（按钮 / 图标 / 开关按下）
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规过渡（面板展开、对话框、控件状态变化）
  static const Duration normal = Duration(milliseconds: 260);

  /// 较慢过渡（页面转场、大幅位移）
  static const Duration slow = Duration(milliseconds: 380);

  /// 列表逐项错开出现的间隔
  static const Duration stagger = Duration(milliseconds: 35);

  /// 主曲线：进入用（快起慢收）
  static const Curve curve = Curves.easeOutCubic;

  /// 退出用曲线
  static const Curve curveIn = Curves.easeInCubic;

  /// 强调曲线（带回弹），用于悬浮控件展开
  static const Curve spring = Curves.easeOutBack;
}

/// 全局页面转场：新页面淡入并轻微上移。
///
/// 替换 Android 默认的整屏缩放转场（低端机掉帧，且与本 App 的
/// 静态文档观感不符），所有平台统一为同一种柔和过渡。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: AppAnim.curve);
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: SlideTransition(
        position:
            Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero)
                .animate(curved),
        child: child,
      ),
    );
  }
}

/// 延迟淡入 + 上滑。列表 / 网格项常用：
/// `FadeSlideIn(delay: AppAnim.stagger * i, child: card)` 即得到错落出现效果。
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppAnim.normal,
    this.offset = const Offset(0, 0.12),
    this.curve = AppAnim.curve,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;
  final Curve curve;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    _a = CurvedAnimation(parent: _c, curve: widget.curve);
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _a,
        child: SlideTransition(
          position: Tween<Offset>(begin: widget.offset, end: Offset.zero)
              .animate(_a),
          child: widget.child,
        ),
      );
}

/// 按压缩放反馈。任何可点击元素包一层即可获得"按下去缩一下"的手感，
/// 长按 / 点击回调透传，不影响原有交互。
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.88,
    this.duration = AppAnim.fast,
    this.tooltip,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final Duration duration;
  final String? tooltip;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (mounted && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    Widget inner = AnimatedScale(
      scale: _down ? widget.scale : 1.0,
      duration: widget.duration,
      curve: AppAnim.curve,
      child: widget.child,
    );
    if (widget.tooltip != null) {
      inner = Tooltip(message: widget.tooltip!, child: inner);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: inner,
    );
  }
}

/// 循环脉冲：用于"正在录音"等需要持续吸引注意的状态。
class Pulse extends StatefulWidget {
  const Pulse({
    super.key,
    required this.child,
    this.min = 1.0,
    this.max = 1.16,
    this.duration = const Duration(milliseconds: 900),
    this.enabled = true,
  });

  final Widget child;
  final double min;
  final double max;
  final Duration duration;
  final bool enabled;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration)
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return ScaleTransition(
      scale: Tween<double>(begin: widget.min, end: widget.max).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// 内容切换的交叉淡入（带轻微缩放）。
///
/// 注意：调用处必须给 child 不同的 `key`（如 `ValueKey(_tool)`），
/// 否则 AnimatedSwitcher 认为内容没变、不会播放动画。
class SwitchFade extends StatelessWidget {
  const SwitchFade({
    super.key,
    required this.child,
    this.duration = AppAnim.normal,
    this.axis = Axis.horizontal,
    this.slide = true,
  });

  final Widget child;
  final Duration duration;
  final Axis axis;
  final bool slide;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: duration,
        switchInCurve: AppAnim.curve,
        switchOutCurve: AppAnim.curveIn,
        transitionBuilder: (c, a) {
          final curved = CurvedAnimation(parent: a, curve: AppAnim.curve);
          final offset = axis == Axis.horizontal
              ? const Offset(0.06, 0)
              : const Offset(0, 0.06);
          return FadeTransition(
            opacity: a,
            child: slide
                ? SlideTransition(
                    position: Tween<Offset>(begin: offset, end: Offset.zero)
                        .animate(curved),
                    child: c,
                  )
                : c,
          );
        },
        child: child,
      );
}

/// 统一风格的底部面板：圆角 + 顶部小手柄 + 滑入动画。
Future<T?> appSheet<T>({
  required BuildContext context,
  required Widget child,
  double? height,
  String? title,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: SizedBox(
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(ctx).dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    ),
  );
}

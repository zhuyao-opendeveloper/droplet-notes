import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 静态场景缓存 —— 把「底图 + 纸张模板 + 图片 + 文本框 + 已提交笔迹」预录成一张 [ui.Picture]。
///
/// 对应 Notein 架构里的「局部重绘 / 分层渲染」思路：
/// 书写过程中，真正随手指变化的只有**当前这一笔**；已提交的历史笔迹是静态的。
/// 若每帧都把成百上千条历史笔迹重画一遍，笔画一多就会掉帧。
///
/// 做法：静态部分只在内容真正变化时重新录制一次，之后每帧只 `drawPicture` 一次，
/// 再叠画活动笔画 / 选中框 / 套索 / 放大窗等动态元素。
///
/// 失效由调用方显式触发（[invalidate]）—— 用「列表对象是否换了」来判断，
/// 而不是去逐条比较内容，这样既不误判也不会漏判：
/// 就算调用方每次都传新列表，最坏也只是退化成每帧重录（结果仍然正确，只是没优化）。
class SceneCache {
  ui.Picture? _picture;
  bool _dirty = true;

  /// 标记场景已变化，下次绘制时重新录制。
  void invalidate() => _dirty = true;

  /// 缓存是否有效（未失效且已录制过）。
  bool get isValid => !_dirty && _picture != null;

  /// 返回当前场景：缓存有效则直接复用，否则用 [draw] 重新录制。
  ui.Picture pictureFor(Size size, void Function(Canvas canvas) draw) {
    if (_picture != null && !_dirty) return _picture!;
    _picture?.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    draw(canvas);
    _picture = recorder.endRecording();
    _dirty = false;
    return _picture!;
  }

  /// 释放 GPU 资源（State.dispose 时调用）。
  void dispose() {
    _picture?.dispose();
    _picture = null;
    _dirty = true;
  }
}

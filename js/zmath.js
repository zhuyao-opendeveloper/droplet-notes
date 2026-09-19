/* 智能钢笔（z_math）—— 变宽笔迹引擎。
 *
 * 与 Android 版 lib/engine/z_math.dart 逐行同源，改 Dart → JS。
 * 算法源头是 z_math.js / C 版 z_math.h。
 *
 * 和 perfect_freehand 是两条完全不同的路子：
 *   - perfect_freehand：由中心线生成「闭合轮廓多边形」再填充；
 *   - z_math：沿中心线按「45% 半径」间距盖一串圆点，全部圆合成一条 path
 *     一次 fill，nonzero 缠绕规则自动取并集 —— 没有接缝也不用抗锯齿。
 *
 * 观感：笔迹圆润无尖角笔锋，起笔固定 0.4、收笔收到 0.1 出锋，
 * 粗细完全由书写速度驱动（快则细、慢则粗），不需要压感硬件 —— 这就是它叫
 * 「智能」钢笔的原因：手指 / 鼠标 / 普通触控屏也能写出有粗细变化的字。
 */
(function (global) {
  'use strict';

  // —— 常数（与 Dart 版一致）——
  var REF_STEP = 8.0;      // 参考采样间距(px)：等间隔采样下点间距 ∝ 速度
  var MAX_W = 1.0;
  var MIN_W = 0.05;
  var BEZIER_STEPS = 10;   // 中点二次贝塞尔的细分步数
  var DOT_SPACING = 0.45;  // 圆点间距 = 半径 × 该比例
  var MAX_DOTS = 1600;     // 单笔圆点硬上限，防长笔画掉帧
  var HEAD_W = 0.4;        // 起笔宽度（不收头）
  var TAIL_W = 0.1;        // 收笔宽度（出锋）
  var RATE_LIMIT = 0.12;   // 每点宽度最大变化量（见 widths 注释）

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  /** 与 Dart Point 对齐：{x, y, t?, p?} */
  function hypot(dx, dy) { return Math.sqrt(dx * dx + dy * dy); }

  /** 归一化宽度序列：速度→宽度映射 → 限速 → 二级平滑（与上一个宽度取平均）。 */
  function widths(pts) {
    var n = pts.length, w = new Array(n), last = 0.5, i, cur;
    for (i = 0; i < n; i++) {
      if (i === 0) {
        cur = HEAD_W;
      } else {
        var dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y;
        var d = hypot(dx, dy);
        var s = d / REF_STEP;               // 归一化速度
        cur = clamp((2.0 - s) / 2.0, MIN_W, MAX_W);  // 核心映射：快→细，慢→粗
        var dif = cur - last;
        // 限速：不让宽度在相邻两点间跳变。
        // 原版写的是 max_dif = 距离 × step（与距离成正比），快速划一下 d 轻松超 20px，
        // 此时 max_dif > 1，而宽度取值空间才 [0.05,1] —— 限速形同虚设，屏幕上是「竹节」。
        // 改成绝对量才真正生效。
        if (Math.abs(dif) > RATE_LIMIT) cur = last + (dif > 0 ? RATE_LIMIT : -RATE_LIMIT);
      }
      cur = clamp((cur + last) / 2, MIN_W, MAX_W);  // 原版的第二层平滑
      w[i] = cur;
      last = cur;
    }
    if (n >= 2) w[n - 1] = TAIL_W;
    return w;
  }

  /** 中点二次贝塞尔平滑 + 位置/宽度同步插值。返回 {x:[], y:[], w:[]}。 */
  function smooth(pts, ws) {
    var ox = [], oy = [], ow = [], n = pts.length, i, s, t, it, a, b, c;
    if (n < 2) {
      if (n === 1) { ox.push(pts[0].x); oy.push(pts[0].y); ow.push(ws[0]); }
      return { x: ox, y: oy, w: ow };
    }
    ox.push(pts[0].x); oy.push(pts[0].y); ow.push(ws[0]);
    if (n === 2) {
      ox.push(pts[1].x); oy.push(pts[1].y); ow.push(ws[1]);
      return { x: ox, y: oy, w: ow };
    }
    // 起点 = 上一段终点（ox/oy/ow 末尾），控制点 = P[i]，终点 = mid(P[i], P[i+1])
    for (i = 1; i <= n - 2; i++) {
      var cx = pts[i].x, cy = pts[i].y, cw = ws[i];
      var ex = (pts[i].x + pts[i + 1].x) / 2;
      var ey = (pts[i].y + pts[i + 1].y) / 2;
      var ew = (ws[i] + ws[i + 1]) / 2;
      var sx = ox[ox.length - 1], sy = oy[oy.length - 1], sw = ow[ow.length - 1];
      for (s = 1; s <= BEZIER_STEPS; s++) {
        t = s / BEZIER_STEPS; it = 1 - t;
        a = it * it; b = 2 * t * it; c = t * t;
        ox.push(a * sx + b * cx + c * ex);
        oy.push(a * sy + b * cy + c * ey);
        ow.push(a * sw + b * cw + c * ew);
      }
    }
    ox.push(pts[n - 1].x); oy.push(pts[n - 1].y); ow.push(ws[n - 1]);
    return { x: ox, y: oy, w: ow };
  }

  /** 平滑后的中心线 + 逐点半径（页面坐标）。 */
  function profile(points, size) {
    var pts = points, ws = widths(pts);
    var sm = smooth(pts, ws);
    var half = clamp(size / 2.0, 0.3, 100000.0);
    var r = new Array(sm.w.length), i;
    for (i = 0; i < sm.w.length; i++) r[i] = clamp(sm.w[i] * half, 0.45, half * 1.5);
    return { x: sm.x, y: sm.y, r: r };
  }

  /** 沿中心线按弧长步进盖圆点（首尾各强制一个，保证端头是圆的）。 */
  function fillPath(ctx, p) {
    var n = p.x.length, i;
    if (!n) return;
    if (n === 1) { dot(ctx, p.x[0], p.y[0], p.r[0]); return; }
    var total = 0;
    for (i = 1; i < n; i++) total += hypot(p.x[i] - p.x[i - 1], p.y[i] - p.y[i - 1]);
    var avgR = 0;
    for (i = 0; i < n; i++) avgR += p.r[i];
    avgR /= n;
    var spacing = clamp(avgR * DOT_SPACING, 0.35, 10000.0);
    if (total / spacing > MAX_DOTS) spacing = total / MAX_DOTS;

    // 单次 beginPath 里叠所有 circle 子路径，最后一次 fill —— nonzero 缠绕自动取并集。
    // 逐圆 fill 的话，相邻圆的半透明边缘会反复叠加，接缝处颜色变深。
    ctx.beginPath();
    sub(ctx, p.x[0], p.y[0], p.r[0]);
    var acc = 0;
    for (i = 1; i < n; i++) {
      acc += hypot(p.x[i] - p.x[i - 1], p.y[i] - p.y[i - 1]);
      if (acc >= spacing) { acc = 0; sub(ctx, p.x[i], p.y[i], p.r[i]); }
    }
    sub(ctx, p.x[n - 1], p.y[n - 1], p.r[n - 1]);
    ctx.fill();
  }

  function sub(ctx, x, y, r) { ctx.moveTo(x + r, y); ctx.arc(x, y, r, 0, Math.PI * 2); }
  function dot(ctx, x, y, r) { ctx.beginPath(); sub(ctx, x, y, r); ctx.fill(); }

  global.ZMath = {
    profile: profile,
    widths: widths,
    smooth: smooth,
    fillPath: fillPath,
    HEAD_W: HEAD_W, TAIL_W: TAIL_W, RATE_LIMIT: RATE_LIMIT
  };
  // node 单测用
  if (typeof module !== 'undefined' && module.exports) module.exports = global.ZMath;
})(typeof window !== 'undefined' ? window : globalThis);

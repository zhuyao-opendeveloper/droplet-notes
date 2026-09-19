/* 渲染引擎 —— 把页面里的笔画画到 Canvas 上。
 *
 * 与 Android 版 widgets/handwriting_canvas.dart 的绘制分支一一对应：
 *   智能钢笔  ZMath 沿中心线盖圆点（dots 并集）
 *   钢笔/毛笔 同一套圆点渲染，只是宽度曲线不同（分别是压感驱动 / 速度大幅驱动）
 *   铅笔/矢量笔 变宽/等宽描边
 *   荧光笔    加粗半透明 + multiply 混色
 *   彩虹笔    沿弧长做色相循环，逐段上色
 *   激光笔    多层辉光（屏幕临时层，不落盘）
 *   形状      规整几何 + 可选填充
 *   胶带笔    半透明缎带
 */
(function (global) {
  'use strict';

  var PAPER = { light: '#FFFFFF', paper: '#F5ECD7', dark: '#121319' };
  var INK = { light: '#DEDEDE', paper: '#DCD0B4', dark: '#2A2A33' };

  function clamp(v, a, b) { return v < a ? a : (v > b ? b : v); }

  /** 扁平点数组 [x,y,p,...] → [{x,y,p}] */
  function toPoints(pts) {
    var out = [], i;
    for (i = 0; i + 2 < pts.length + 1; i += 3) out.push({ x: pts[i], y: pts[i + 1], p: pts[i + 2] });
    return out;
  }

  function hexToRgb(h) {
    h = (h || '#000000').replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var v = parseInt(h, 16);
    return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
  }
  function rgba(hex, a) {
    var c = hexToRgb(hex);
    return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + a + ')';
  }
  /** 由旅程距离算色相（0..1 循环一周），与 Android rainbow 分支同一思路 */
  function hueCycle(t) {
    var h = ((t % 1) + 1) % 1 * 6, r, g, b;
    var i = Math.floor(h), f = h - i;
    switch (i) {
      case 0: r = 1; g = f; b = 0; break;
      case 1: r = 1 - f; g = 1; b = 0; break;
      case 2: r = 0; g = 1; b = f; break;
      case 3: r = 0; g = 1 - f; b = 1; break;
      case 4: r = f; g = 0; b = 1; break;
      default: r = 1; g = 0; b = 1 - f;
    }
    return 'rgb(' + Math.round(r * 255) + ',' + Math.round(g * 255) + ',' + Math.round(b * 255) + ')';
  }

  // ---------- 宽度曲线 ----------
  /** 压感驱动：有点触/手写笔时直接用 p；没有就落回 0.75 常数。 */
  function pressureWidths(pts, opts) {
    var n = pts.length, w = new Array(n), i, p;
    for (i = 0; i < n; i++) {
      p = pts[i].p;
      if (p == null || p <= 0) p = 0.75;
      // 收笔 15% 出锋，起笔 55% 起势
      var head = clamp(i / Math.max(1, n * 0.06), 0, 1);
      var tail = clamp((n - 1 - i) / Math.max(1, n * 0.15), 0, 1);
      w[i] = clamp(p, 0.05, 1) * (0.55 + 0.45 * head) * (0.25 + 0.75 * tail) * (opts && opts.k ? opts.k : 1);
    }
    return w;
  }

  function stamp(ctx, prof, radiusOf) {
    var n = prof.x.length, i;
    if (!n) return;
    if (n === 1) {
      ctx.beginPath();
      ctx.moveTo(prof.x[0] + (radiusOf ? radiusOf(prof.w[0]) : prof.w[0]), prof.y[0]);
      ctx.arc(prof.x[0], prof.y[0], (radiusOf ? radiusOf(prof.w[0]) : prof.w[0]), 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    var total = 0, dx, dy;
    for (i = 1; i < n; i++) {
      dx = prof.x[i] - prof.x[i - 1]; dy = prof.y[i] - prof.y[i - 1];
      total += Math.sqrt(dx * dx + dy * dy);
    }
    var step = Math.max(0.35, (total / Math.max(1, n)) * 0.6);
    ctx.beginPath();
    addDot(ctx, prof, 0, radiusOf);
    for (i = 1; i < n; i++) {
      dx = prof.x[i] - prof.x[i - 1]; dy = prof.y[i] - prof.y[i - 1];
      if (Math.sqrt(dx * dx + dy * dy) >= step) addDot(ctx, prof, i, radiusOf);
    }
    addDot(ctx, prof, n - 1, radiusOf);
    ctx.fill();
  }

  function addDot(ctx, prof, i, radiusOf) {
    var r = radiusOf ? radiusOf(prof.w[i]) : prof.w[i];
    ctx.moveTo(prof.x[i] + r, prof.y[i]);
    ctx.arc(prof.x[i], prof.y[i], r, 0, Math.PI * 2);
  }

  // ---------- 各工具 ----------
  function drawFreeStroke(ctx, s) {
    var pts = toPoints(s.pts);
    if (!pts.length) return;
    var size = s.size || 3;
    ctx.save();
    ctx.globalAlpha = s.opacity == null ? 1 : s.opacity;
    ctx.fillStyle = s.color || '#000';
    ctx.strokeStyle = s.color || '#000';
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    switch (s.type) {
      case 'smartPen': {
        if (!global.ZMath) break;
        ctx.fillStyle = s.color;
        global.ZMath.fillPath(ctx, global.ZMath.profile(pts, size));
        break;
      }
      case 'pen': {
        // 钢笔：有压感用压感，没有压感时 p 缺失 → pressureWidths 落回 0.75 常数，
        // 再叠加「起笔起势 + 收笔出锋」的形状因子，写出来的仍有书写味。
        var prof = { x: [], y: [], w: pressureWidths(pts, { k: 1 }) };
        for (var i = 0; i < pts.length; i++) { prof.x.push(pts[i].x); prof.y.push(pts[i].y); }
        ctx.fillStyle = s.color;
        stamp(ctx, prof, function (w) { return Math.max(0.35, w * size * 0.5); });
        break;
      }
      case 'brush': {
        var pw = pressureWidths(pts, { k: 1.25 });
        var bp = { x: [], y: [], w: pw };
        for (var j = 0; j < pts.length; j++) { bp.x.push(pts[j].x); bp.y.push(pts[j].y); }
        ctx.fillStyle = s.color;
        stamp(ctx, bp, function (w) { return Math.max(0.4, w * size * 0.62); });
        break;
      }
      case 'pencil': {
        // 铅笔：硬边、等宽、略带颗粒感（用两段 alpha 叠一层模拟石墨纹理）
        ctx.lineWidth = Math.max(0.6, size * 0.5);
        ctx.globalAlpha = (s.opacity == null ? 1 : s.opacity) * 0.75;
        poly(ctx, pts);
        ctx.stroke();
        ctx.globalAlpha = (s.opacity == null ? 1 : s.opacity) * 0.35;
        ctx.lineWidth = Math.max(0.6, size * 0.5) + 0.8;
        poly(ctx, pts);
        ctx.stroke();
        break;
      }
      case 'vector': {
        ctx.lineWidth = Math.max(0.6, size * 0.55);
        poly(ctx, pts);
        ctx.stroke();
        break;
      }
      case 'highlighter': {
        ctx.globalCompositeOperation = 'multiply';
        ctx.globalAlpha = (s.opacity == null ? 1 : s.opacity) * 0.38;
        ctx.lineWidth = Math.max(2, size * 2.4);
        ctx.lineCap = 'butt';
        poly(ctx, pts);
        ctx.stroke();
        break;
      }
      case 'tape': {
        ctx.globalAlpha = (s.opacity == null ? 1 : s.opacity) * 0.45;
        ctx.fillStyle = s.color;
        ctx.lineWidth = Math.max(4, size * 6);
        ctx.lineCap = 'butt';
        poly(ctx, pts);
        ctx.stroke();
        break;
      }
      case 'rainbow': {
        // 逐段上色：整笔一个颜色没法表达「沿弧长色相循环」
        if (pts.length < 2) { break; }
        ctx.lineCap = 'round';
        var total = 0, segLens = [], d;
        for (var k = 1; k < pts.length; k++) {
          d = Math.hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y);
          segLens.push(d); total += d;
        }
        var acc = 0, w = Math.max(0.8, size * 0.55);
        for (var q = 1; q < pts.length; q++) {
          ctx.strokeStyle = hueCycle(acc / Math.max(1, total));
          ctx.lineWidth = w;
          ctx.beginPath();
          ctx.moveTo(pts[q - 1].x, pts[q - 1].y);
          ctx.lineTo(pts[q].x, pts[q].y);
          ctx.stroke();
          acc += segLens[q - 1];
        }
        break;
      }
      default: {
        ctx.lineWidth = Math.max(0.6, size * 0.55);
        poly(ctx, pts);
        ctx.stroke();
      }
    }
    ctx.restore();
  }

  function poly(ctx, pts) {
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    if (pts.length === 1) ctx.lineTo(pts[0].x + 0.01, pts[0].y);
  }

  /** 形状：pts 是规整化后的控制点（2 点对角 / 4 点旋转矩形 / 3 点三角） */
  function drawShape(ctx, s) {
    var p = s.pts || [], i;
    if (!p.length) return;
    ctx.save();
    ctx.globalAlpha = s.opacity == null ? 1 : s.opacity;
    ctx.strokeStyle = s.color || '#000';
    ctx.lineWidth = Math.max(0.8, (s.size || 3) * 0.6);
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    var path = new Path2D();
    switch (s.type) {
      case 'line':
        path.moveTo(p[0][0], p[0][1]); path.lineTo(p[1][0], p[1][1]);
        ctx.stroke(path);
        break;
      case 'arrow': {
        path.moveTo(p[0][0], p[0][1]); path.lineTo(p[1][0], p[1][1]);
        ctx.stroke(path);
        arrowHead(ctx, p[0], p[1], (s.size || 3) * 2.2, s.color);
        break;
      }
      case 'rect':
        if (p.length >= 4) {
          path.moveTo(p[0][0], p[0][1]);
          for (i = 1; i < 4; i++) path.lineTo(p[i][0], p[i][1]);
          path.closePath();
        } else {
          path.rect(Math.min(p[0][0], p[1][0]), Math.min(p[0][1], p[1][1]),
            Math.abs(p[1][0] - p[0][0]), Math.abs(p[1][1] - p[0][1]));
        }
        if (s.fill) { ctx.fillStyle = s.color; ctx.globalAlpha *= 0.18; ctx.fill(path); ctx.globalAlpha /= 0.18; }
        ctx.stroke(path);
        break;
      case 'ellipse': {
        var cx = (p[0][0] + p[1][0]) / 2, cy = (p[0][1] + p[1][1]) / 2;
        path.ellipse(cx, cy, Math.abs(p[1][0] - p[0][0]) / 2, Math.abs(p[1][1] - p[0][1]) / 2, 0, 0, Math.PI * 2);
        if (s.fill) { ctx.fillStyle = s.color; ctx.globalAlpha *= 0.18; ctx.fill(path); ctx.globalAlpha /= 0.18; }
        ctx.stroke(path);
        break;
      }
      case 'triangle':
        path.moveTo(p[0][0], p[0][1]);
        path.lineTo(p[1][0], p[1][1]);
        path.lineTo(p[2][0], p[2][1]);
        path.closePath();
        if (s.fill) { ctx.fillStyle = s.color; ctx.globalAlpha *= 0.18; ctx.fill(path); ctx.globalAlpha /= 0.18; }
        ctx.stroke(path);
        break;
    }
    ctx.restore();
  }

  function arrowHead(ctx, a, b, len, color) {
    var ang = Math.atan2(b[1] - a[1], b[0] - a[0]);
    ctx.save();
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(b[0], b[1]);
    ctx.lineTo(b[0] - len * Math.cos(ang - 0.42), b[1] - len * Math.sin(ang - 0.42));
    ctx.lineTo(b[0] - len * Math.cos(ang + 0.42), b[1] - len * Math.sin(ang + 0.42));
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  function drawText(ctx, s) {
    ctx.save();
    ctx.globalAlpha = s.opacity == null ? 1 : s.opacity;
    ctx.fillStyle = s.color || '#000';
    ctx.font = (s.bold ? 'bold ' : '') + (s.size || 18) + 'px "Segoe UI", system-ui, "Microsoft YaHei", sans-serif';
    ctx.textBaseline = 'top';
    var lines = String(s.text == null ? '' : s.text).split('\n'), lh = (s.size || 18) * 1.35;
    for (var i = 0; i < lines.length; i++) ctx.fillText(lines[i], s.x, s.y + i * lh);
    ctx.restore();
  }

  var SHAPES = { line: 1, rect: 1, ellipse: 1, triangle: 1, arrow: 1 };

  function drawStroke(ctx, s) {
    if (s.hidden) return;
    if (s.type === 'text') return drawText(ctx, s);
    if (s.type === 'image') {
      var img = s._img;
      if (img) {
        if (s.crop) {
          // crop 是原图上的归一化矩形 —— 先取源区域，再画到目标框里
          ctx.drawImage(img, s.crop.x * s.imgW, s.crop.y * s.imgH, s.crop.w * s.imgW, s.crop.h * s.imgH,
            s.x, s.y, s.w, s.h);
        } else {
          ctx.drawImage(img, s.x, s.y, s.w, s.h);
        }
      }
      return;
    }
    if (SHAPES[s.type]) return drawShape(ctx, s);
    return drawFreeStroke(ctx, s);
  }

  // ---------- 纸张背景 ----------
  function paperColor(page, dark) {
    if (dark) return PAPER.dark;
    return page.dark ? PAPER.dark : (Store.settings().theme === 'paper' ? PAPER.paper : PAPER.light);
  }

  function drawBackground(ctx, page, w, h, dark) {
    var bg = page.bg || 'blank';
    ctx.fillStyle = paperColor(page, dark);
    ctx.fillRect(0, 0, w, h);
    if (bg === 'blank') return;
    var ink = (dark || page.dark) ? INK.dark : (Store.settings().theme === 'paper' ? INK.paper : INK.light);
    ctx.save();
    ctx.strokeStyle = ink;
    ctx.fillStyle = ink;
    ctx.lineWidth = 1;
    if (bg === 'ruled') {
      var gap = 34;
      for (var y = gap; y < h; y += gap) {
        ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(w, y + 0.5); ctx.stroke();
      }
    } else if (bg === 'grid') {
      var g = Store.settings().gridSize || 24;
      ctx.beginPath();
      for (var x = g; x < w; x += g) { ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, h); }
      for (var y2 = g; y2 < h; y2 += g) { ctx.moveTo(0, y2 + 0.5); ctx.lineTo(w, y2 + 0.5); }
      ctx.stroke();
    } else if (bg === 'dot') {
      var d2 = Store.settings().gridSize || 24;
      for (var x2 = d2; x2 < w; x2 += d2)
        for (var y3 = d2; y3 < h; y3 += d2) {
          ctx.beginPath(); ctx.arc(x2, y3, 1.3, 0, Math.PI * 2); ctx.fill();
        }
    } else if (bg === 'cornell') {
      // 康奈尔：底部总结区 + 右侧线索栏
      ctx.beginPath();
      ctx.moveTo(0.5, h - 150.5); ctx.lineTo(w, h - 150.5);
      ctx.moveTo(w * 0.72, 0.5); ctx.lineTo(w * 0.72, h - 150.5);
      ctx.stroke();
      ctx.globalAlpha = 0.6;
      for (var y4 = 190; y4 < h - 150; y4 += 34) {
        ctx.beginPath(); ctx.moveTo(0, y4 + 0.5); ctx.lineTo(w * 0.72, y4 + 0.5); ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }
    ctx.restore();
  }

  function drawPage(ctx, page, w, h, dark) {
    drawBackground(ctx, page, w, h, dark);
    var st = page.strokes || [];
    for (var i = 0; i < st.length; i++) drawStroke(ctx, st[i]);
  }

  /** 激光笔：多层辉光，越靠中心越白越亮。
   *  这是一层屏幕临时效果，不进 undo 栈也不落盘。 */
  function drawLaser(ctx, s) {
    var pts = toPoints(s.pts);
    if (pts.length < 2) return;
    ctx.save();
    var base = s.color || '#FF3B30';
    var w = s.size || 4;
    // 同样必须沿「中心线」描 —— 用轮廓配 stroke 只会得到一圈空心边线
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    var layers = [
      [w * 5.0, 8, 120, 0.12],
      [w * 2.4, 4, 60, 0.35],
      [w * 1.2, 2, 30, 0.75]
    ];
    layers.forEach(function (L) {
      ctx.strokeStyle = rgba(base, L[3]);
      ctx.lineWidth = clamp(w * L[0], L[1], L[2]);
      poly(ctx, pts);
      ctx.stroke();
    });
    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = clamp(w * 0.38, 0.6, 12);
    poly(ctx, pts);
    ctx.stroke();
    ctx.restore();
  }

  global.Render = {
    drawStroke: drawStroke,
    drawShape: drawShape,
    drawText: drawText,
    drawPage: drawPage,
    drawBackground: drawBackground,
    drawLaser: drawLaser,
    paperColor: paperColor,
    toPoints: toPoints,
    rgba: rgba,
    hueCycle: hueCycle
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = global.Render;
})(typeof window !== 'undefined' ? window : globalThis);

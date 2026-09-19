/* 手绘图形自动识别 —— 移植自 Android 版 lib/engine/shape_recognizer.dart
 * （Python 复刻版见仓库根 _shape_test.py，本文件与其判定流程一致）。
 *
 * 随手画一笔 → 识别成 直线 / 矩形 / 椭圆(正圆) / 三角形 / 箭头，
 * 识别不出来的保持原样（curve）。
 *
 * 全部基于几何特征，无外部依赖，纯离线：
 *   开放笔画：直线度 → 箭头（还要端点回勾）/ 直线
 *   闭合笔画：绕行系数过滤涂鸦 → 矩形度 / 三角度 / 圆度
 * 复杂度：重采样到 48 点后，凸包 O(n log n)、最大面积三角形 O(h³)、
 * 最小外接矩形旋转卡壳 O(h·n)，单笔毫秒级。
 */
(function (global) {
  'use strict';

  function dist(a, b) { var dx = b[0] - a[0], dy = b[1] - a[1]; return Math.sqrt(dx * dx + dy * dy); }

  function bbox(p) {
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (var i = 0; i < p.length; i++) {
      if (p[i][0] < x0) x0 = p[i][0];
      if (p[i][1] < y0) y0 = p[i][1];
      if (p[i][0] > x1) x1 = p[i][0];
      if (p[i][1] > y1) y1 = p[i][1];
    }
    return [x0, y0, x1, y1];
  }

  function pathLen(p) { var s = 0; for (var i = 1; i < p.length; i++) s += dist(p[i - 1], p[i]); return s; }

  function resample(src, n) {
    var raw = [], i;
    for (i = 0; i < src.length; i++) {
      if (!raw.length || dist(src[i], raw[raw.length - 1]) > 0.01) raw.push(src[i]);
    }
    if (raw.length < 2) return raw;
    var cum = [0.0], total;
    for (i = 1; i < raw.length; i++) cum.push(cum[i - 1] + dist(raw[i - 1], raw[i]));
    total = cum[cum.length - 1];
    if (total <= 0) return raw;
    var step = total / (n - 1);
    var out = [raw[0]], idx = 1, d = step, seg, t;
    while (out.length < n - 1 && idx < raw.length) {
      while (idx < raw.length && cum[idx] < d) idx++;
      if (idx >= raw.length) break;
      seg = cum[idx] - cum[idx - 1];
      t = seg > 0 ? Math.max(0, Math.min(1, (d - cum[idx - 1]) / seg)) : 0;
      out.push([raw[idx - 1][0] + (raw[idx][0] - raw[idx - 1][0]) * t,
                raw[idx - 1][1] + (raw[idx][1] - raw[idx - 1][1]) * t]);
      d += step;
    }
    out.push(raw[raw.length - 1]);
    return out;
  }

  function cross(o, a, b) { return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]); }

  function convexHull(pts) {
    if (pts.length < 3) return pts.slice();
    var p = pts.map(function (q) { return [q[0], q[1]]; }).sort(function (a, b) {
      return a[0] - b[0] || a[1] - b[1];
    });
    // 去重
    var u = [];
    for (var i = 0; i < p.length; i++) {
      if (!u.length || u[u.length - 1][0] !== p[i][0] || u[u.length - 1][1] !== p[i][1]) u.push(p[i]);
    }
    var lower = [], upper = [], k;
    for (i = 0; i < u.length; i++) {
      while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], u[i]) <= 0) lower.pop();
      lower.push(u[i]);
    }
    for (i = u.length - 1; i >= 0; i--) {
      while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], u[i]) <= 0) upper.pop();
      upper.push(u[i]);
    }
    lower.pop(); upper.pop();
    return lower.concat(upper);
  }

  function polyArea(p) {
    var a = 0, i, j;
    for (i = 0; i < p.length; i++) {
      j = (i + 1) % p.length;
      a += p[i][0] * p[j][1] - p[j][0] * p[i][1];
    }
    return Math.abs(a / 2);
  }

  function polyPerim(p) { var s = 0; for (var i = 0; i < p.length; i++) s += dist(p[i], p[(i + 1) % p.length]); return s; }

  function triArea(a, b, c) {
    return Math.abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2;
  }

  function maxAreaTriangle(h) {
    var n = h.length, best = -1, bt = null, i, j, k, a;
    for (i = 0; i < n - 2; i++)
      for (j = i + 1; j < n - 1; j++)
        for (k = j + 1; k < n; k++) {
          a = triArea(h[i], h[j], h[k]);
          if (a > best) { best = a; bt = [h[i], h[j], h[k]]; }
        }
    return bt;
  }

  /** 旋转卡壳求最小外接矩形 → [cx, cy, w, h, angle] */
  function minAreaRect(hull) {
    var n = hull.length, i;
    if (n < 3) {
      var b = bbox(hull);
      return [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2, b[2] - b[0], b[3] - b[1], 0];
    }
    var bestArea = Infinity, best = null;
    for (i = 0; i < n; i++) {
      var j = (i + 1) % n;
      var dx = hull[j][0] - hull[i][0], dy = hull[j][1] - hull[i][1];
      var L = Math.sqrt(dx * dx + dy * dy);
      if (L <= 0) continue;
      var ang = Math.atan2(dy, dx);
      var ca = Math.cos(-ang), sa = Math.sin(-ang);
      var xs = [], ys = [], q;
      for (q = 0; q < hull.length; q++) {
        xs.push(hull[q][0] * ca - hull[q][1] * sa);
        ys.push(hull[q][0] * sa + hull[q][1] * ca);
      }
      var w = Math.max.apply(null, xs) - Math.min.apply(null, xs);
      var h = Math.max.apply(null, ys) - Math.min.apply(null, ys);
      if (w * h < bestArea) {
        bestArea = w * h;
        var cx = (Math.min.apply(null, xs) + Math.max.apply(null, xs)) / 2;
        var cy = (Math.min.apply(null, ys) + Math.max.apply(null, ys)) / 2;
        var cb = Math.cos(ang), sb = Math.sin(ang);
        best = [cx * cb - cy * sb, cx * sb + cy * cb, w, h, ang];
      }
    }
    return best;
  }

  function angBetween(u, v) {
    var d = u[0] * v[0] + u[1] * v[1];
    var nu = Math.sqrt(u[0] * u[0] + u[1] * u[1]), nv = Math.sqrt(v[0] * v[0] + v[1] * v[1]);
    if (nu <= 0 || nv <= 0) return 0;
    return Math.acos(Math.max(-1, Math.min(1, d / (nu * nv))));
  }

  function ringDist(a, b, n) { var d = Math.abs(a - b) % n; return Math.min(d, n - d); }

  /** 曲率角点检测（闭合轮廓用） */
  function cornersClosed(p, tolerance) {
    var n = p.length;
    if (n < 12) return [];
    var k = Math.max(2, Math.min(6, Math.round(n / 12)));
    var thr = 55.0 - tolerance * 10;
    var cand = [], i, d;
    for (i = 0; i < n; i++) {
      cand.push(angBetween([p[(i - k + n) % n][0] - p[i][0], p[(i - k + n) % n][1] - p[i][1]],
                           [p[(i + k) % n][0] - p[i][0], p[(i + k) % n][1] - p[i][1]]) * 180 / Math.PI);
    }
    var idx = [];
    for (i = 0; i < n; i++) {
      if (cand[i] < thr) continue;
      var ismax = true;
      for (d = 1; d <= k; d++) {
        if (cand[(i + d) % n] > cand[i] || cand[(i - d + n) % n] > cand[i]) { ismax = false; break; }
      }
      if (!ismax) continue;
      if (!idx.length || ringDist(i, idx[idx.length - 1], n) > k) idx.push(i);
    }
    if (idx.length > 1 && ringDist(idx[0], idx[idx.length - 1], n) <= k) idx.pop();
    return idx;
  }

  /** 端点回勾检测：0=无 1=尾端是箭头 2=首端是箭头 */
  function detectArrowHead(pts, tolerance) {
    var n = pts.length, i;
    if (n < 12) return 0;
    var i1 = Math.round(n * 0.30), i2 = Math.round(n * 0.70);
    var mid = [pts[i2][0] - pts[i1][0], pts[i2][1] - pts[i1][1]];
    if (Math.sqrt(mid[0] * mid[0] + mid[1] * mid[1]) < 1e-6) return 0;
    var turnThr = (100 - tolerance * 20) * Math.PI / 180, detour = 1.5;
    var tailPath = 0, headPath = 0;
    for (i = i2 + 1; i < n; i++) tailPath += dist(pts[i - 1], pts[i]);
    for (i = 1; i <= i1; i++) headPath += dist(pts[i - 1], pts[i]);
    var tailVec = [pts[n - 1][0] - pts[i2][0], pts[n - 1][1] - pts[i2][1]];
    var tailChord = Math.sqrt(tailVec[0] * tailVec[0] + tailVec[1] * tailVec[1]);
    var tailArrow = (tailChord > 0 && tailPath > tailChord * detour) ||
      (tailChord > 1e-6 && angBetween(mid, tailVec) > turnThr);
    var headVec = [pts[0][0] - pts[i1][0], pts[0][1] - pts[i1][1]];
    var headChord = Math.sqrt(headVec[0] * headVec[0] + headVec[1] * headVec[1]);
    var headArrow = (headChord > 0 && headPath > headChord * detour) ||
      (headChord > 1e-6 && angBetween([-mid[0], -mid[1]], headVec) > turnThr);
    if (tailArrow && !headArrow) return 1;
    if (headArrow && !tailArrow) return 2;
    if (tailArrow && headArrow) return 1;
    return 0;
  }

  /**
   * 识别主流程。
   * @param {Array<[x,y]>} raw 原始采样点
   * @param {number} tolerance 0=严格 0.5=标准 1.0=宽松
   * @returns {{kind:string, data:*, score:number}}
   *   kind: line|rect|ellipse|triangle|arrow|curve
   *   data: line/arrow→{a,b}；rect/ellipse→最小外接矩形；triangle→三顶点
   */
  function recognize(raw, tolerance) {
    var tol = Math.max(0, Math.min(1, tolerance === undefined ? 0.5 : tolerance));
    if (!raw || raw.length < 4) return { kind: 'curve', data: null, score: 0 };

    var pts = resample(raw, 48);
    if (pts.length < 4) return { kind: 'curve', data: null, score: 0 };
    var ln = pathLen(pts);
    var bb = bbox(pts);
    var diag = Math.sqrt((bb[2] - bb[0]) * (bb[2] - bb[0]) + (bb[3] - bb[1]) * (bb[3] - bb[1]));
    if (ln <= 0 || diag < 24) return { kind: 'curve', data: null, score: 0 };  // 极小笔画（顿号）保留手绘

    var chord = dist(pts[0], pts[pts.length - 1]);
    var straightness = chord / ln;
    var closed = chord < 0.28 * (1 + tol * 0.5) * ln;

    if (!closed) {
      // 箭头要先判：箭头整体直线度只有 0.6 上下，先按直线阈值卡就永远识别不到，
      // 得靠「主干够直 + 端点回勾」单独区分（波浪线直线度 0.70 但无回勾）。
      var ah = detectArrowHead(pts, tol);
      if (straightness > 0.55 && ah) return { kind: 'arrow', data: ah, score: straightness };
      if (straightness > 0.84 * (1 - tol * 0.14)) return { kind: 'line', data: null, score: straightness };
      return { kind: 'curve', data: null, score: 0 };
    }

    var hull = convexHull(pts);
    if (hull.length < 3) return { kind: 'curve', data: null, score: 0 };
    var hp = polyPerim(hull);
    if (hp <= 0) return { kind: 'curve', data: null, score: 0 };
    // 绕行系数 = 路径长 / 凸包周长。空心轮廓 ≈1.0，涂鸦/来回穿越 >2
    if (ln / hp > 1.45) return { kind: 'curve', data: null, score: 0 };

    var ha = polyArea(hull);
    var circ = 4 * Math.PI * ha / (hp * hp);
    var mr = minAreaRect(hull);
    var rectRatio = (mr[2] > 0 && mr[3] > 0) ? ha / (mr[2] * mr[3]) : 0;
    var tri = maxAreaTriangle(hull);
    var triRatio = ha > 0 ? triArea(tri[0], tri[1], tri[2]) / ha : 0;

    var k = 1 - tol * 0.16;
    // 圆的矩形度理论上限是 π/4≈0.785，阈值下限绝不能低于它，否则圆会被误判成矩形
    if (rectRatio > Math.max(0.86, 0.95 * k)) return { kind: 'rect', data: mr, score: rectRatio };
    if (triRatio > Math.max(0.70, 0.86 * k)) return { kind: 'triangle', data: tri, score: triRatio };
    if (circ > Math.max(0.72, 0.78 * k)) return { kind: 'ellipse', data: mr, score: circ };
    if (rectRatio > 0.84) return { kind: 'rect', data: mr, score: rectRatio };
    if (triRatio > 0.66) return { kind: 'triangle', data: tri, score: triRatio };
    if (circ > 0.66) return { kind: 'ellipse', data: mr, score: circ };
    return { kind: 'curve', data: null, score: 0 };
  }

  /** 由识别结果 + 原始点求规整化后的控制点（给 renderer 用）。 */
  function toShapePoints(kind, data, raw) {
    function firstLast() {
      var a = raw[0], b = raw[raw.length - 1];
      return [[a.x, a.y], [b.x, b.y]];
    }
    switch (kind) {
      case 'line':
      case 'arrow': {
        var fl = firstLast();
        if (data === 1) return fl;                                  // 箭头尖在尾端
        if (data === 2) return [fl[1], fl[0]];
        return fl;
      }
      case 'rect': {
        // 旋转矩形用四角，轴对齐的程度高就退化成对角两点，绘制时更好用
        var ang = data[4];
        var axisAligned = Math.abs(Math.sin(ang)) < 0.08 || Math.abs(Math.cos(ang)) < 0.08;
        if (axisAligned) {
          return [[data[0] - data[2] / 2, data[1] - data[3] / 2], [data[0] + data[2] / 2, data[1] + data[3] / 2]];
        }
        var pts4 = [], ca = Math.cos(ang), sa = Math.sin(ang);
        var loc = [[-data[2] / 2, -data[3] / 2], [data[2] / 2, -data[3] / 2], [data[2] / 2, data[3] / 2], [-data[2] / 2, data[3] / 2]];
        for (var i = 0; i < 4; i++) {
          pts4.push([data[0] + loc[i][0] * ca - loc[i][1] * sa, data[1] + loc[i][0] * sa + loc[i][1] * ca]);
        }
        return pts4;
      }
      case 'ellipse':
        return [[data[0] - data[2] / 2, data[1] - data[3] / 2], [data[0] + data[2] / 2, data[1] + data[3] / 2]];
      case 'triangle':
        return data;
      default:
        return null;
    }
  }

  var API = {
    recognize: recognize,
    toShapePoints: toShapePoints,
    resample: resample,
    convexHull: convexHull,
    minAreaRect: minAreaRect,
    polyArea: polyArea,
    detectArrowHead: detectArrowHead
  };
  global.Recognizer = API;
  if (typeof module !== 'undefined' && module.exports) module.exports = API;
})(typeof window !== 'undefined' ? window : globalThis);

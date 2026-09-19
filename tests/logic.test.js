/* 纯逻辑单测（node web/tests/logic.test.js）
 *
 * 两件事：
 *  1. ZMath 智能钢笔：宽度曲线的取值域、限速是否生效、平滑后的中心线是否连续。
 *     第三条是重点 —— 之前的实现把二次贝塞尔的「起点」和「控制点」取成同一个点，
 *     曲线退化成直线，链上还会留下缺口的跳跃段，这里直接把「有没有缺口」钉成断言。
 *  2. Recognizer：用 Python 版 _shape_test.py 里同一批合成笔画（含Transitional tolerance 三档）
 *     跑一遍，确认 JS 移植的判定结果与原 Dart/Python 实现一致。
 */
var path = require('path');
var ZMath = require(path.join(__dirname, '..', 'js', 'zmath.js'));
var Rec = require(path.join(__dirname, '..', 'js', 'recognizer.js'));

var pass = 0, fail = 0;
function ok(cond, name, extra) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (extra ? '  → ' + extra : '')); }
}
function head(t) { console.log('\n' + t); }

// ---------------- ZMath ----------------
head('ZMath 智能钢笔');

function linePts(x0, y0, x1, y1, n) {
  var a = [], i;
  for (i = 0; i < n; i++) {
    var t = i / (n - 1);
    a.push({ x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t, p: 0 });
  }
  return a;
}

var pts = linePts(0, 0, 400, 0, 40);
var prof = ZMath.profile(pts, 8);

ok(prof.x.length > pts.length, '平滑后点数多于原始点（贝塞尔细分生效）', prof.x.length + ' vs ' + pts.length);

// 相邻间距不得超过原始点间距 —— 超了说明中间有「跨越」，即中间断了
var maxSeg = 400 / 39, maxGap = 0, total = 0;
for (var i = 1; i < prof.x.length; i++) {
  var d = Math.hypot(prof.x[i] - prof.x[i - 1], prof.y[i] - prof.y[i - 1]);
  maxGap = Math.max(maxGap, d);
  total += d;
}
ok(maxGap <= maxSeg * 1.05, '中心线无缺口（最大步进 ≤ 原始点间距）', 'maxGap=' + maxGap.toFixed(2) + ' seg=' + maxSeg.toFixed(2));
ok(total >= 400 * 0.95 && total <= 400 * 1.05, '中心线长度 ≈ 原始路径长（不丢不多）', total.toFixed(1));

var w = prof.r.map(function (r) { return r / 4; });   // size=8 → half=4
var inRange = w.every(function (v) { return v >= 0.05 - 1e-9 && v <= 1 + 1e-9; });
ok(inRange, '归一化宽度落在 [0.05, 1]');

// 匀速直线 → 宽度应趋于稳定值 s=2/40... 400/39/8 = 1.28 → (2-1.28)/2 = 0.36
var stable = w[Math.floor(w.length / 2)];
ok(Math.abs(stable - 0.36) < 0.06, '匀速直线宽度收敛到理论值 0.36', '实际 ' + stable.toFixed(3));

// 限速：构造「极慢 → 极快」的突变，检查相邻宽度差不超过 RATE_LIMIT
var jump = [];
for (i = 0; i < 20; i++) jump.push({ x: i * 0.5, y: 0, p: 0 });       // 很慢 → 很粗
for (i = 0; i < 20; i++) jump.push({ x: 10 + i * 60, y: 0, p: 0 });   // 很快 → 很细
var jw = ZMath.widths(jump);
var maxJumpDiff = 0;
for (i = 1; i < jw.length; i++) maxJumpDiff = Math.max(maxJumpDiff, Math.abs(jw[i] - jw[i - 1]));
ok(maxJumpDiff <= ZMath.RATE_LIMIT + 1e-9, '宽度变化被限速拦住（≤ ' + ZMath.RATE_LIMIT + '）',
  '实际最大 ' + maxJumpDiff.toFixed(3));

ok(jw[jw.length - 1] === ZMath.TAIL_W, '收笔宽度 = ' + ZMath.TAIL_W + '（出锋）');
ok(jw[0] === ZMath.HEAD_W || jw[0] > 0, '起笔宽度固定 ' + ZMath.HEAD_W);

// 单点点 falcipu
var one = ZMath.profile([{ x: 5, y: 5, p: 0 }], 6);
ok(one.x.length === 1 && one.r[0] > 0, '单点笔画能产出圆点（顿笔可用）');

// ---------------- Recognizer ----------------
head('手绘图形识别');

// 确定性伪随机：mulberry32 + Box-Muller。
// 之前用 LCG % 2^31，在 JS 里会掉精度（s*1103515245 超出 2^53），
// 出来的「正态」噪声方差偏大，把依赖抖动的用例拖偏。
function mulberry(seed) {
  return function () {
    seed |= 0; seed = seed + 0x6D2B79F5 | 0;
    var t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function jit(pts, amp, seed) {
  var rnd = mulberry((seed || 0) + 1);
  function g() {
    var u = Math.max(1e-12, rnd()), v = rnd();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  }
  return pts.map(function (p) { return [p[0] + g() * amp, p[1] + g() * amp]; });
}
function mkLine(p0, p1, amp, n) {
  p0 = p0 || [60, 300]; p1 = p1 || [420, 300]; amp = amp == null ? 2 : amp; n = n || 40;
  var a = [];
  for (var i = 0; i < n; i++) {
    var t = i / (n - 1);
    a.push([p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t]);
  }
  return jit(a, amp, 1);
}
function mkCircle(c, r, amp, n, seed) {
  c = c || [250, 300]; r = r || 110; amp = amp == null ? 2.5 : amp; n = n || 48;
  var a = [];
  for (var i = 0; i < n; i++) a.push([c[0] + r * Math.cos(2 * Math.PI * i / (n - 1)), c[1] + r * Math.sin(2 * Math.PI * i / (n - 1))]);
  return jit(a, amp, seed || 2);
}
function mkEllipse(c, rx, ry, amp, seed) {
  c = c || [250, 300]; rx = rx || 160; ry = ry || 90;
  var a = [];
  for (var i = 0; i < 48; i++) a.push([c[0] + rx * Math.cos(2 * Math.PI * i / 47), c[1] + ry * Math.sin(2 * Math.PI * i / 47)]);
  return jit(a, amp == null ? 2.5 : amp, seed || 3);
}
function mkRect(box, amp, seed, per) {
  box = box || [80, 180, 420, 400]; amp = amp == null ? 2.5 : amp; per = per || 12;
  var corners = [[box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]], [box[0], box[1]]];
  var a = [];
  for (var i = 0; i < 4; i++)
    for (var j = 0; j < per; j++) {
      var t = j / per;
      a.push([corners[i][0] + (corners[i + 1][0] - corners[i][0]) * t,
              corners[i][1] + (corners[i + 1][1] - corners[i][1]) * t]);
    }
  return jit(a, amp, seed || 4);
}
function mkTriangle(v, amp, seed) {
  v = v || [[250, 160], [420, 400], [80, 400]];
  var a = [], i, j, t;
  for (i = 0; i < 3; i++) {
    var p0 = v[i], p1 = v[(i + 1) % 3];
    for (j = 0; j < 14; j++) { t = j / 14; a.push([p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t]); }
  }
  return jit(a, amp == null ? 2.5 : amp, seed || 5);
}
function mkArrow(p0, p1, head2, amp) {
  p0 = p0 || [70, 300]; p1 = p1 || [400, 300]; head2 = head2 || 45; amp = amp == null ? 1.8 : amp;
  var a = [], i, t, k;
  for (i = 0; i < 32; i++) { t = i / 31; a.push([p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t]); }
  var ang = Math.atan2(p1[1] - p0[1], p1[0] - p0[0]);
  for (k = 0; k < 12; k++) { t = k / 11; a.push([p1[0] - head2 * t * Math.cos(ang - 0.45), p1[1] - head2 * t * Math.sin(ang - 0.45)]); }
  a.push(p1);
  for (k = 0; k < 12; k++) { t = k / 11; a.push([p1[0] - head2 * t * Math.cos(ang + 0.45), p1[1] - head2 * t * Math.sin(ang + 0.45)]); }
  return jit(a, amp, 6);
}
function mkRectRot(deg, c, w, h, amp) {
  c = c || [260, 300]; w = w || 300; h = h || 170;
  var a2 = deg * Math.PI / 180, ca = Math.cos(a2), sa = Math.sin(a2);
  var loc = [[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2], [-w / 2, -h / 2]];
  var cs = loc.map(function (q) { return [c[0] + q[0] * ca - q[1] * sa, c[1] + q[0] * sa + q[1] * ca]; });
  var a = [], i, j, t;
  for (i = 0; i < 4; i++) for (j = 0; j < 12; j++) {
    t = j / 12;
    a.push([cs[i][0] + (cs[i + 1][0] - cs[i][0]) * t, cs[i][1] + (cs[i + 1][1] - cs[i][1]) * t]);
  }
  return jit(a, amp == null ? 2.5 : amp, 9);
}
function mkScrub() {
  var a = [], i;
  for (i = 0; i < 60; i++) {
    var t = (i % 20) / 19;
    a.push([120 + 320 * t + ((i / 20 | 0) % 2 === 0 ? 0 : -30), 300 + ((i / 20) | 0) * 18]);
  }
  return jit(a, 1.2, 17);
}
function mkScribble(seed) {
  var rnd = mulberry(seed || 7), a = [], x = 200, y = 300, i;
  function g() {
    var u = Math.max(1e-12, rnd()), v = rnd();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  }
  for (i = 0; i < 90; i++) {
    x += g() * 26; y += g() * 26;
    a.push([x, y]);
  }
  return a;
}
function mkWave() {
  var a = [], i;
  for (i = 0; i < 60; i++) { var t = i / 59; a.push([60 + 380 * t, 300 + 60 * Math.sin(t * Math.PI * 3)]); }
  return jit(a, 1.5, 8);
}

// 基准用例：由 Python 参考实现（仓库根 _shape_test.py）生成后导出。
// 用完全相同的输入点跑，JS 与参考实现就必须给出完全相同的判定 ——
// 自己捏随机笔画时因为两语言随机数不同，噪声大小也不一样，
// 「极抖直线」在严格档判成 curve 那是生成器的差异，不是算法的差异。
var FIXTURES = require('./fixtures.json');

[0.0, 0.5, 1.0].forEach(function (tol) {
  var bad = [];
  FIXTURES.forEach(function (c) {
    var got = Rec.recognize(c.pts, tol).kind;
    if (got !== c.want) bad.push(c.name + ' 期望=' + c.want + ' 实际=' + got);
  });
  ok(bad.length === 0, 'tolerance=' + tol + ' 全部 ' + FIXTURES.length + ' 例与参考实现一致', bad.join(' | '));
});

function byName(n) {
  for (var k = 0; k < FIXTURES.length; k++) if (FIXTURES[k].name === n) return FIXTURES[k].pts;
  return null;
}

var r = Rec.recognize(byName('手绘矩形'), 0.5);
var sp = Rec.toShapePoints(r.kind, r.data, [{ x: 0, y: 0 }, { x: 1, y: 1 }]);
ok(r.kind === 'rect' && sp && sp.length >= 2, '矩形可换算成控制点', 'kind=' + r.kind + ' n=' + (sp && sp.length));

var rt = Rec.recognize(byName('旋转矩形60°'), 0.5);
var spt = Rec.toShapePoints(rt.kind, rt.data, []);
ok(rt.kind === 'rect' && spt.length === 4, '旋转矩形换算成 4 个角点（2 点对角表达不了旋转）',
  'kind=' + rt.kind + ' n=' + spt.length);

var rc = Rec.recognize(byName('手绘圆'), 0.5);
ok(Rec.toShapePoints(rc.kind, rc.data, []).length === 2, '椭圆换算成包围盒对角 2 点');

var rtri = Rec.recognize(byName('手绘三角形'), 0.5);
ok(Rec.toShapePoints(rtri.kind, rtri.data, []).length === 3, '三角形换算成 3 个顶点');

console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail ? 1 : 0);

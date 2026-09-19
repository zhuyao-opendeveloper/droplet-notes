/* 编辑器 —— 对应 Android 版 ui/editor.dart + widgets/handwriting_canvas.dart。
 *
 * 左侧竖排工具盘（顺序与手机版 _rail() 一致）、顶部工具栏、右侧属性/AI 面板、
 * 中间画布（支持缩放平移、压感、套索、手绘图形自动识别、撤销重做、图层）。
 */
(function (global) {
  'use strict';

  var DN = global.DN, Store = global.Store, Render = global.Render;

  var TOOLS = [
    ['pen', 'pen', '钢笔'],
    ['brush', 'brush', '毛笔'],
    ['highlighter', 'highlight', '荧光笔'],
    ['pencil', 'pencil', '铅笔'],
    ['rainbow', 'rainbow', '彩虹笔'],
    ['vector', 'vector', '矢量笔'],
    ['smartPen', 'edit', '智能钢笔（无需压感，粗细随速度）'],
    ['tape', 'tape', '胶带笔'],
    ['eraser', 'eraser', '橡皮'],
    ['laser', 'laser', '激光笔（临时笔迹，不落盘）'],
    ['line', 'line', '直线'],
    ['rect', 'rect', '矩形'],
    ['ellipse', 'ellipse', '椭圆'],
    ['triangle', 'triangle', '三角形'],
    ['arrow', 'arrow', '箭头'],
    ['lasso', 'lasso', '套索'],
    ['text', 'text', '文本'],
    ['image', 'image', '插入图片'],
    ['crop', 'crop', '图片裁剪']
  ];
  var PENLIKE = { pen: 1, brush: 1, highlighter: 1, pencil: 1, rainbow: 1, vector: 1, smartPen: 1, tape: 1, laser: 1 };
  var SHAPES = { line: 1, rect: 1, ellipse: 1, triangle: 1, arrow: 1 };
  var PALETTE = Store.PALETTE;

  var S = {
    note: null,
    page: 0,
    tool: 'smartPen',
    color: PALETTE[0],
    size: 4,
    opacity: 1,
    fill: false,
    scale: 1, tx: 0, ty: 0,
    undo: [], redo: [],
    sel: null,          // 套索选中的笔画集合
    dirty: true,
    panel: 'prop',      // prop | ai | layers
    drawing: null,      // 正在写的笔画
    preview: null,      // 形状 / 套索预览
    laser: null,
    aiBusy: false,
    ctrl: null          // 中断 AI 用
  };

  var cv, ctx, wrap;

  // ---------- 视图与坐标 ----------
  function page() { return S.note ? S.note.pages[S.page] : null; }

  function fitView() {
    var p = page();
    if (!p) return;
    var r = wrap.getBoundingClientRect();
    S.scale = Math.min(r.width / p.width, r.height / p.height) * 0.96;
    S.tx = (r.width - p.width * S.scale) / 2;
    S.ty = (r.height - p.height * S.scale) / 2;
    S.dirty = true;
  }

  function toPage(clientX, clientY) {
    var r = cv.getBoundingClientRect();
    return { x: (clientX - r.left - S.tx) / S.scale, y: (clientY - r.top - S.ty) / S.scale };
  }
  function toScreen(p) { return { x: p.x * S.scale + S.tx, y: p.y * S.scale + S.ty }; }

  function resize() {
    if (!wrap) return;
    var r = wrap.getBoundingClientRect();
    var dpr = Math.min(global.devicePixelRatio || 1, 2);
    cv.width = Math.max(1, Math.round(r.width * dpr));
    cv.height = Math.max(1, Math.round(r.height * dpr));
    cv.style.width = r.width + 'px';
    cv.style.height = r.height + 'px';
    S.dpr = dpr;
    S.dirty = true;
  }

  // ---------- 渲染 ----------
  function frame() {
    if (!S.note) return;
    if (S.dirty) draw();
    requestAnimationFrame(frame);
  }

  function draw() {
    S.dirty = false;
    var p = page();
    if (!p) return;
    var dpr = S.dpr || 1;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, cv.width, cv.height);
    ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--canvas-bg').trim() || '#EEE';
    ctx.fillRect(0, 0, cv.width, cv.height);
    ctx.setTransform(dpr * S.scale, 0, 0, dpr * S.scale, dpr * S.tx, dpr * S.ty);
    Render.drawPage(ctx, p, p.width, p.height, Store.settings().dark);
    if (S.drawing) Render.drawStroke(ctx, S.drawing);
    if (S.preview) drawPreview(ctx);
    if (S.laser) Render.drawLaser(ctx, S.laser);
    if (S.sel && S.sel.list.length) drawSelection(ctx);
  }

  function drawPreview(c) {
    c.save();
    c.strokeStyle = S.color;
    c.globalAlpha = 0.85;
    c.lineWidth = Math.max(0.8, S.size * 0.6) / 1;
    c.lineJoin = 'round'; c.lineCap = 'round';
    var q = S.preview;
    if (q.kind === 'shape') {
      Render.drawShape(c, {
        type: q.tool === 'line' ? 'line' : q.tool, pts: q.pts, color: S.color, size: S.size, opacity: 1, fill: S.fill
      });
    } else if (q.kind === 'marquee') {
      c.setLineDash([6 / S.scale, 4 / S.scale]);
      c.lineWidth = 1.2 / S.scale;
      c.strokeStyle = '#3B5BDB';
      c.strokeRect(q.x0, q.y0, q.x1 - q.x0, q.y1 - q.y0);
    } else if (q.kind === 'move') {
      c.globalAlpha = 0.5;
      q.list.forEach(function (st) {
        var cp = shiftStroke(st, q.dx, q.dy);
        Render.drawStroke(c, cp);
      });
      c.globalAlpha = 1;
    }
    c.restore();
  }

  function shiftStroke(st, dx, dy) {
    var cp = JSON.parse(JSON.stringify(st));
    if (cp.type === 'text') { cp.x += dx; cp.y += dy; return cp; }
    if (cp.type === 'image') { cp.x += dx; cp.y += dy; return cp; }
    if (SHAPES[cp.type]) { cp.pts = cp.pts.map(function (p) { return [p[0] + dx, p[1] + dy]; }); return cp; }
    for (var i = 0; i + 2 < cp.pts.length; i += 3) { cp.pts[i] += dx; cp.pts[i + 1] += dy; }
    return cp;
  }

  function drawSelection(c) {
    c.save();
    c.strokeStyle = '#3B5BDB';
    c.lineWidth = 1.2 / S.scale;
    c.setLineDash([5 / S.scale, 4 / S.scale]);
    S.sel.list.forEach(function (st) {
      var b = strokeBounds(st);
      c.strokeRect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0);
    });
    c.restore();
  }

  function strokeBounds(st) {
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, i;
    function acc(x, y) { if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; }
    if (st.type === 'text') { acc(st.x, st.y); acc(st.x + 200, st.y + (st.size || 18) * 1.4); }
    else if (st.type === 'image') { acc(st.x, st.y); acc(st.x + st.w, st.y + st.h); }
    else if (SHAPES[st.type]) { st.pts.forEach(function (p) { acc(p[0], p[1]); }); }
    else {
      for (i = 0; i + 2 < st.pts.length; i += 3) acc(st.pts[i], st.pts[i + 1]);
    }
    if (x0 === Infinity) { x0 = y0 = 0; x1 = y1 = 0; }
    return { x0: x0, y0: y0, x1: x1, y1: y1 };
  }

  // ---------- 撤销 / 保存 ----------
  function snapshot() {
    var p = page();
    if (!p) return;
    S.undo.push({ pi: S.page, data: JSON.stringify(p.strokes) });
    if (S.undo.length > 60) S.undo.shift();
    S.redo.length = 0;
    // 不刷新按钮状态的话，写完一笔后「撤销」还是灰的（客户区 Ctrl+Z 能用、按钮点不动）
    syncBar();
  }

  function restore(from, to) {
    var cur = page();
    if (!cur) return;
    var rec = from.pop();
    if (!rec) return;
    to.push({ pi: S.page, data: JSON.stringify(cur.strokes) });
    S.page = rec.pi;
    S.note.pages[rec.pi].strokes = JSON.parse(rec.data);
    save();
    S.dirty = true;
    syncBar();
  }

  var saveTimer = null;
  function save() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      if (S.note) Store.saveNote(S.note);
    }, 350);
  }

  // ---------- 工具栏 / 面板 ----------
  function railHtml() {
    return TOOLS.map(function (t) {
      return '<button class="rail-btn' + (S.tool === t[0] ? ' sel' : '') + '" data-tool="' + t[0] +
        '" title="' + DN.esc(t[2]) + '">' + DN.icon(t[1], 22) + '</button>';
    }).join('');
  }

  function propHtml() {
    return '<div class="grp"><span class="lbl">颜色</span><div class="swatches">' +
      PALETTE.map(function (c, i) {
        return '<button class="sw' + (S.color.toUpperCase() === c.toUpperCase() ? ' sel' : '') +
          '" data-color="' + c + '" style="background:' + c + '"></button>';
      }).join('') +
      '<label class="sw custom" title="自定义颜色"><input type="color" id="p-color" value="' + S.color + '"></label>' +
      '</div></div>' +
      '<div class="grp"><span class="lbl">粗细 <em id="p-size-v">' + S.size + '</em></span>' +
      '<input type="range" id="p-size" min="1" max="40" step="1" value="' + S.size + '"></div>' +
      '<div class="grp"><span class="lbl">透明 <em id="p-op-v">' + Math.round(S.opacity * 100) + '%</em></span>' +
      '<input type="range" id="p-op" min="0.1" max="1" step="0.05" value="' + S.opacity + '"></div>' +
      (SHAPES[S.tool] ? '<label class="grp inline"><span>形状填充</span>' +
        '<input type="checkbox" id="p-fill"' + (S.fill ? ' checked' : '') + '></label>' : '') +
      '<div class="grp"><span class="lbl">此页纸张</span><div class="seg" id="p-bg">' +
      [['blank', '空白'], ['ruled', '横线'], ['grid', '网格'], ['dot', '点阵'], ['cornell', '康奈尔']].map(function (b) {
        return '<button class="' + ((page() || {}).bg === b[0] ? 'sel' : '') + '" data-bg="' + b[0] + '">' + b[1] + '</button>';
      }).join('') + '</div></div>' +
      '<p class="hint">' + toolHint() + '</p>';
  }

  function toolHint() {
    switch (S.tool) {
      case 'smartPen': return '智能钢笔：粗细由书写速度决定，鼠标 / 手指也能写出笔锋，不需要压感硬件。';
      case 'pen': return '钢笔：有数位笔时按真实压感变粗细，没有时按固定宽度 + 收笔出锋。';
      case 'rainbow': return '彩虹笔：颜色沿笔迹长度循环，适合做标记。';
      case 'laser': return '激光笔：屏幕上高亮一圈就淡出，不会留在页面上。';
      case 'tape': return '胶带笔：半透明覆盖层，可叠在笔迹上做遮挡标注。';
      case 'eraser': return '橡皮：整笔擦除，点到哪笔画就整笔删除。';
      case 'lasso': return '套索：框选一组笔画后可以整体拖动，或按 Delete 删除。';
      case 'image': return '插入图片：点击后选图，插入后可用「图片裁剪」调整。';
      default: return '写完一笔会做「手绘图形自动识别」，画得像直线/矩形/圆/三角/箭头时会自动变规整。';
    }
  }

  function layersHtml() {
    var p = page();
    if (!p) return '';
    var st = p.strokes;
    if (!st.length) return '<p class="hint">这一页还没有内容。</p>';
    return '<div class="layers">' + st.slice().map(function (s, i) {
      var idx = st.length - 1 - i;   // 上面的笔画显示在最前
      var name = ({ smartPen: '智能钢笔', pen: '钢笔', brush: '毛笔', highlighter: '荧光笔', pencil: '铅笔',
        rainbow: '彩虹笔', vector: '矢量笔', tape: '胶带笔', text: '文本', image: '图片',
        line: '直线', rect: '矩形', ellipse: '椭圆', triangle: '三角形', arrow: '箭头' })[s.type] || s.type;
      return '<div class="layer-row" data-i="' + idx + '">' + DN.icon(iconOf(s.type), 16) +
        '<span>' + name + '</span>' +
        '<button class="icon-btn sm" data-up="' + idx + '" title="上移一层">' + DN.icon('chevron_right', 14) + '</button>' +
        '<button class="icon-btn sm" data-del-s="' + idx + '" title="删除">' + DN.icon('delete', 14) + '</button></div>';
    }).join('') + '</div>';
  }

  function iconOf(t) {
    for (var i = 0; i < TOOLS.length; i++) if (TOOLS[i][0] === t) return TOOLS[i][1];
    return 'pen';
  }

  function syncBar() {
    var p = page();
    if (!p || !S.note) return;
    DN.qs('#ed-title').value = S.note.title;
    DN.qs('#ed-pageinfo').textContent = (S.page + 1) + ' / ' + S.note.pages.length;
    DN.qs('#ed-undo').disabled = !S.undo.length;
    DN.qs('#ed-redo').disabled = !S.redo.length;
  }

  function syncPanel() {
    var box = DN.qs('#ed-panel');
    if (!box) return;
    if (S.panel === 'ai') { box.innerHTML = aiHtml(); bindAi(); }
    else if (S.panel === 'layers') { box.innerHTML = '<h3>图层</h3>' + layersHtml(); }
    else { box.innerHTML = '<h3>属性</h3>' + propHtml(); bindProp(); }
    DN.qsa('#ed-panel [data-icon]').length && ICONS.paint(box);
  }

  function bindProp() {
    var box = DN.qs('#ed-panel');
    box.addEventListener('click', function (e) {
      var b;
      if ((b = e.target.closest('[data-color]'))) { S.color = b.dataset.color; return syncPanel(); }
      if ((b = e.target.closest('[data-bg]'))) {
        var p = page();
        if (p) { p.bg = b.dataset.bg; save(); S.dirty = true; syncPanel(); }
        return;
      }
    });
    var c = DN.qs('#p-color', box);
    if (c) c.addEventListener('input', function () { S.color = this.value; });
    var s = DN.qs('#p-size', box);
    if (s) s.addEventListener('input', function () { S.size = +this.value; DN.qs('#p-size-v', box).textContent = this.value; });
    var o = DN.qs('#p-op', box);
    if (o) o.addEventListener('input', function () {
      S.opacity = +this.value;
      DN.qs('#p-op-v', box).textContent = Math.round(S.opacity * 100) + '%';
    });
    var f = DN.qs('#p-fill', box);
    if (f) f.addEventListener('change', function () { S.fill = this.checked; });
  }

  // ---------- AI 面板 ----------
  function aiHtml() {
    var cfg = Store.aiConfig();
    var ps = global.AI.PRESETS;
    return '<h3>AI 助手 <span class="badge">网页版</span></h3>' +
      '<div class="ai-grid">' + ps.map(function (p) {
        return '<button class="ai-act" data-act="' + p.key + '" title="' + DN.esc(p.hint) + '">' +
          DN.icon(p.icon, 16) + '<span>' + p.label + '</span></button>';
      }).join('') + '</div>' +
      '<div class="grp"><textarea id="ai-q" rows="2" placeholder="直接问这篇笔记里的内容…"></textarea>' +
      '<button class="btn primary sm" id="ai-ask">' + DN.icon('send', 14) + ' 提问</button></div>' +
      '<div class="grp"><div class="row-btns">' +
      '<button class="btn sm" id="ai-stop"' + (S.aiBusy ? '' : ' disabled') + '>停止</button>' +
      '<button class="btn sm" id="ai-copy">复制结果</button>' +
      '<button class="btn sm" id="ai-insert">插入当页</button>' +
      '<button class="btn sm" id="ai-clear">清空</button>' +
      '</div></div>' +
      '<div id="ai-out" class="ai-out"></div>' +
      '<p class="hint">当前：' + DN.esc(cfg.model) + ' @ ' + DN.esc(cfg.baseUrl) +
      (cfg.apiKey ? '（Key 已配置）' : '，<b>还没配 Key</b> —— 到首页 ⚙ 设置里填') + '</p>';
  }

  function bindAi() {
    var box = DN.qs('#ed-panel');
    var out = DN.qs('#ai-out', box);
    box.addEventListener('click', function (e) {
      var b;
      if ((b = e.target.closest('[data-act]'))) return runAi(b.dataset.act);
      if (e.target.closest('#ai-ask')) return runAi('ask');
      if (e.target.closest('#ai-stop')) {
        if (S.ctrl) S.ctrl.abort();
        S.aiBusy = false;
        return;
      }
      if (e.target.closest('#ai-copy')) {
        var t = out.textContent;
        if (!t.trim()) return DN.toast('还没有结果');
        return navigator.clipboard ? navigator.clipboard.writeText(t).then(function () { DN.toast('已复制'); }) : DN.toast('浏览器不支持剪贴板');
      }
      if (e.target.closest('#ai-insert')) {
        var txt = out.textContent.trim();
        if (!txt) return DN.toast('还没有内容可插入');
        var p = page();
        var y = 60;
        p.strokes.forEach(function (s) {
          if (s.type === 'text') y = Math.max(y, s.y + (s.size || 18) * 1.4 * (String(s.text).split('\n').length + 1));
        });
        y = Math.min(y, p.height - 200);
        snapshot();
        p.strokes.push({
          id: Store.uid('s'), type: 'text', text: txt, x: 60, y: y,
          size: 18, color: Store.settings().dark ? '#E8E8EF' : '#1A1A1A', opacity: 1
        });
        save(); S.dirty = true;
        return DN.toast('已插入当页');
      }
      if (e.target.closest('#ai-clear')) { out.textContent = ''; }
    });

    function runAi(key) {
      if (S.aiBusy) return DN.toast('正在生成…');
      var q = DN.qs('#ai-q', box).value.trim();
      if (key === 'ask' && !q) return DN.toast('先写下你的问题');
      var n = global.AI.hasText(S.note);
      if (!n && key !== 'ask') return DN.toast('这篇笔记还没有可识别的文字（先用「T」文本工具写点东西，或识别过后才有内容）');
      S.aiBusy = true;
      S.ctrl = new AbortController();
      out.textContent = '';
      DN.qs('#ai-stop', box).disabled = false;
      global.AI.runPreset(key, S.note, {
        question: q,
        signal: S.ctrl.signal,
        onDelta: function (d) { out.textContent += d; out.scrollTop = out.scrollHeight; },
        onDone: function () { S.aiBusy = false; var s2 = DN.qs('#ai-stop', box); if (s2) s2.disabled = true; },
        onError: function (err) {
          S.aiBusy = false;
          var s3 = DN.qs('#ai-stop', box); if (s3) s3.disabled = true;
          out.textContent = '出错了：' + err.message;
        }
      }).catch(function () { /* onError 已经处理过 */ });
    }
  }

  // ---------- 指针输入 ----------
  function onDown(ev) {
    if (!S.note) return;
    cv.setPointerCapture(ev.pointerId);
    var pt = toPage(ev.clientX, ev.clientY);
    var press = ev.pressure && ev.pressure > 0 && ev.pointerType === 'pen' ? ev.pressure : null;

    if (S.tool === 'image') { pickImage(); return; }
    if (S.tool === 'crop') { cropDialog(); return; }
    if (S.tool === 'text') { editTextAt(pt); return; }

    if (S.tool === 'eraser') { snapshot(); eraseAt(pt); return void (S.erasing = true); }
    if (S.tool === 'lasso') {
      S.preview = { kind: 'marquee', x0: pt.x, y0: pt.y, x1: pt.x, y1: pt.y };
      return void (S.marquee = true);
    }
    if (S.sel && S.sel.list.length) {
      var b = unionBounds(S.sel.list);
      if (pt.x >= b.x0 && pt.x <= b.x1 && pt.y >= b.y0 && pt.y <= b.y1) {
        S.preview = { kind: 'move', list: S.sel.list, dx: 0, dy: 0, from: pt };
        return void (S.moving = true);
      }
      S.sel = null;
      S.dirty = true;
    }

    if (SHAPES[S.tool]) {
      // 预览点必须用 shapePoints 生成：三角形要 3 个顶点，
      // 沿用「起点 + 终点」两点的写法，按下还没拖动时 drawShape 去读 p[2] 会当场抛错
      S.preview = { kind: 'shape', tool: S.tool, start: pt, pts: shapePoints(S.tool, pt, pt, false) };
      // 形状笔画也要进撤销栈 —— 之前只有书写工具 push 快照，画完的形状 Ctrl+Z 撤不掉
      snapshot();
      return void (S.shaping = true);
    }

    snapshot();
    S.drawing = {
      id: Store.uid('s'), type: S.tool, color: S.color, size: S.size, opacity: S.opacity,
      pts: [pt.x, pt.y, press || 0]
    };
    S.dirty = true;
  }

  function onMove(ev) {
    if (!S.note) return;
    var pt = toPage(ev.clientX, ev.clientY);
    if (S.erasing) return void eraseAt(pt);
    if (S.marquee && S.preview) {
      S.preview.x1 = pt.x; S.preview.y1 = pt.y;
      S.dirty = true;
      return;
    }
    if (S.moving && S.preview) {
      S.preview.dx = pt.x - S.preview.from.x;
      S.preview.dy = pt.y - S.preview.from.y;
      S.dirty = true;
      return;
    }
    if (S.shaping && S.preview) {
      var a = S.preview.start;
      S.preview.pts = shapePoints(S.tool, a, pt, ev.shiftKey);
      S.dirty = true;
      return;
    }
    if (!S.drawing) return;
    var d = S.drawing.pts;
    var n = d.length;
    // 采样去重：太密的点只会拖慢渲染，也压缩不了什么信息
    if (n >= 3 && Math.hypot(pt.x - d[n - 3], pt.y - d[n - 2]) < 1.6) return;
    var press = ev.pressure && ev.pressure > 0 && ev.pointerType === 'pen' ? ev.pressure : 0;
    d.push(pt.x, pt.y, press || 0);
    S.dirty = true;
  }

  function onUp(ev) {
    cv.releasePointerCapture && ev.pointerId != null && cv.hasPointerCapture && cv.hasPointerCapture(ev.pointerId) &&
      cv.releasePointerCapture(ev.pointerId);
    var p = page();
    if (!p) return;

    if (S.erasing) { S.erasing = false; save(); return; }
    if (S.marquee) {
      S.marquee = false;
      var q = S.preview;
      var sel = p.strokes.filter(function (s) {
        var b = strokeBounds(s);
        return !(b.x1 < Math.min(q.x0, q.x1) || b.x0 > Math.max(q.x0, q.x1) ||
          b.y1 < Math.min(q.y0, q.y1) || b.y0 > Math.max(q.y0, q.y1));
      });
      S.sel = { list: sel };
      S.preview = null;
      S.dirty = true;
      if (sel.length) DN.toast('选中 ' + sel.length + ' 笔，拖动可移动，Delete 删除');
      return;
    }
    if (S.moving) {
      var pv = S.preview;
      S.moving = false;
      S.preview = null;
      if (pv && (Math.abs(pv.dx) > 0.5 || Math.abs(pv.dy) > 0.5)) {
        snapshot();
        pv.list.forEach(function (st) {
          var cp = shiftStroke(st, pv.dx, pv.dy);
          for (var k in cp) st[k] = cp[k];
        });
        save();
      }
      S.dirty = true;
      return;
    }
    if (S.shaping) {
      S.shaping = false;
      var sp = S.preview;
      S.preview = null;
      var pts = sp.pts;
      var degenerate = Math.abs(pts[1][0] - pts[0][0]) < 3 && Math.abs(pts[1][1] - pts[0][1]) < 3;
      if (!degenerate) {
        p.strokes.push({
          id: Store.uid('s'), type: sp.tool, pts: pts, color: S.color, size: S.size,
          opacity: S.opacity, fill: SHAPES[sp.tool] ? S.fill : false
        });
        save();
      }
      S.dirty = true;
      return;
    }
    if (!S.drawing) return;

    var st = S.drawing;
    S.drawing = null;
    var n = st.pts.length / 3;
    if (n < 1) { S.dirty = true; return; }

    if (S.tool === 'laser') {
      // 激光笔不进 undo 栈也不落盘：它就是屏幕上一闪而过的指示光
      S.laser = st;
      S.dirty = true;
      setTimeout(function () { S.laser = null; S.dirty = true; }, 1200);
      return;
    }
    if (n < 2 && st.pts.length >= 3) st.pts.push(st.pts[0] + 0.6, st.pts[1], st.pts[2] || 0);

    var recognized = null;
    if (Store.settings().autoShape && (S.tool === 'pen' || S.tool === 'pencil' || S.tool === 'brush')) {
      var raw = [];
      for (var i = 0; i + 2 < st.pts.length; i += 3) raw.push([st.pts[i], st.pts[i + 1]]);
      var r = global.Recognizer.recognize(raw, Store.settings().shapeTolerance);
      if (r.kind !== 'curve') {
        var rp = global.Recognizer.toShapePoints(r.kind, r.data, Render.toPoints(st.pts));
        recognized = { id: st.id, type: r.kind, pts: rp, color: st.color, size: st.size, opacity: st.opacity, fill: S.fill };
      }
    }
    p.strokes.push(recognized || st);
    if (recognized) DN.toast('识别成' + ({ line: '直线', rect: '矩形', ellipse: '椭圆', triangle: '三角形', arrow: '箭头' })[recognized.type]);
    save();
    S.dirty = true;
    if (S.panel === 'layers') syncPanel();
  }

  function unionBounds(list) {
    var b = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
    list.forEach(function (s) {
      var q = strokeBounds(s);
      b.x0 = Math.min(b.x0, q.x0); b.y0 = Math.min(b.y0, q.y0);
      b.x1 = Math.max(b.x1, q.x1); b.y1 = Math.max(b.y1, q.y1);
    });
    return b;
  }

  /** 形状工具的规整控制点：整数 offered 2 点对角 / 3 点三角 */
  function shapePoints(tool, a, b, square) {
    var x0 = a.x, y0 = a.y, x1 = b.x, y1 = b.y;
    if ((tool === 'rect' || tool === 'ellipse') && square) {
      var s = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0));
      x1 = x0 + (x1 > x0 ? s : -s);
      y1 = y0 + (y1 > y0 ? s : -s);
    }
    switch (tool) {
      case 'line':
      case 'arrow':
        return [[x0, y0], [x1, y1]];
      case 'triangle':
        // 沿用手机版：拖出的框里画一个顶角居中的等腰三角形
        return [[Math.min(x0, x1), Math.max(y0, y1)], [Math.max(x0, x1), Math.max(y0, y1)],
        [(x0 + x1) / 2, Math.min(y0, y1)]];
      default:
        return [[x0, y0], [x1, y1]];
    }
  }

  function eraseAt(pt) {
    var p = page();
    if (!p) return;
    var r = Math.max(6, S.size * 3);
    var hit = null, bestD = Infinity;
    for (var i = p.strokes.length - 1; i >= 0; i--) {
      var s = p.strokes[i];
      if (s.type === 'image') {
        if (pt.x >= s.x && pt.x <= s.x + s.w && pt.y >= s.y && pt.y <= s.y + s.h) { hit = i; break; }
        continue;
      }
      var dd = distToStroke(s, pt);
      if (dd < r + (s.size || 3) * 0.5 && dd < bestD) { bestD = dd; hit = i; }
    }
    if (hit != null) {
      p.strokes.splice(hit, 1);
      if (S.sel) S.sel.list = S.sel.list.filter(function (s) { return p.strokes.indexOf(s) >= 0; });
      S.dirty = true;
    }
  }

  function distToStroke(s, pt) {
    var best = Infinity, pts, i;
    if (s.type === 'text') {
      return (pt.x >= s.x && pt.x <= s.x + 240 && pt.y >= s.y - 4 && pt.y <= s.y + (s.size || 18) * 1.4) ? 0 : Infinity;
    }
    if (SHAPES[s.type]) {
      pts = s.pts.map(function (q) { return { x: q[0], y: q[1] }; });
    } else {
      pts = Render.toPoints(s.pts);
    }
    for (i = 1; i < pts.length; i++) best = Math.min(best, distSeg(pt, pts[i - 1], pts[i]));
    if (pts.length === 1) best = Math.min(best, Math.hypot(pt.x - pts[0].x, pt.y - pts[0].y));
    return best;
  }

  function distSeg(p, a, b) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var L2 = dx * dx + dy * dy;
    if (L2 === 0) return Math.hypot(p.x - a.x, p.y - a.y);
    var t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2));
    return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
  }

  // ---------- 文本 ----------
  function editTextAt(pt) {
    var p = page();
    if (!p) return;
    var sp = toScreen(pt);
    var ta = DN.el('<textarea class="float-text" style="left:' + sp.x + 'px;top:' + sp.y +
      'px;font-size:' + (Math.max(12, S.size * 4) * S.scale) + 'px;color:' + S.color +
      ';opacity:' + S.opacity + '"></textarea>');
    wrap.appendChild(ta);
    ta.focus();
    function finish(commit) {
      var v = ta.value;
      ta.remove();
      if (commit && v.trim()) {
        snapshot();
        p.strokes.push({
          id: Store.uid('s'), type: 'text', text: v, x: pt.x, y: pt.y,
          size: Math.max(12, S.size * 4), color: S.color, opacity: S.opacity
        });
        save();
        S.dirty = true;
      }
    }
    ta.addEventListener('blur', function () { finish(true); });
    ta.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { finish(false); }
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { finish(true); }
    });
  }

  // ---------- 图片 ----------
  function pickImage() {
    var inp = DN.el('<input type="file" accept="image/*" style="display:none">');
    document.body.appendChild(inp);
    inp.addEventListener('change', function () {
      var f = this.files && this.files[0];
      this.remove();
      if (!f) return;
      var fr = new FileReader();
      fr.onload = function () {
        var img = new Image();
        img.onload = function () {
          var p = page();
          if (!p) return;
          var w = Math.min(p.width * 0.7, img.width);
          var h = w / img.width * img.height;
          snapshot();
          var st = {
            id: Store.uid('s'), type: 'image', src: fr.result, imgW: img.width, imgH: img.height,
            x: 80, y: 120, w: w, h: h, crop: null, opacity: 1
          };
          st._img = img;
          p.strokes.push(st);
          save();
          S.dirty = true;
          DN.toast('图片已插入');
        };
        img.src = fr.result;
      };
      fr.readAsDataURL(f);
    });
    inp.click();
  }

  function ensureImages() {
    var p = page();
    if (!p) return Promise.resolve();
    var jobs = [];
    p.strokes.forEach(function (s) {
      if (s.type === 'image' && !s._img) {
        jobs.push(new Promise(function (res) {
          var im = new Image();
          im.onload = im.onerror = function () { s._img = im; res(); };
          im.src = s.src;
        }));
      }
    });
    return Promise.all(jobs).then(function () { S.dirty = true; });
  }

  function cropDialog() {
    var p = page();
    if (!p) return;
    var list = p.strokes.filter(function (s) { return s.type === 'image'; });
    if (!list.length) return DN.toast('这一页还没有图片');
    var st = list[list.length - 1];
    var c = st.crop || { x: 0, y: 0, w: 1, h: 1 };
    DN.dialog({
      title: '图片裁剪',
      body: '<div id="crop-prev" class="crop-prev"></div>' +
        '<div class="grp"><span class="lbl">左</span><input type="range" id="c-x" min="0" max="0.9" step="0.01" value="' + c.x + '"></div>' +
        '<div class="grp"><span class="lbl">上</span><input type="range" id="c-y" min="0" max="0.9" step="0.01" value="' + c.y + '"></div>' +
        '<div class="grp"><span class="lbl">宽</span><input type="range" id="c-w" min="0.05" max="1" step="0.01" value="' + c.w + '"></div>' +
        '<div class="grp"><span class="lbl">高</span><input type="range" id="c-h" min="0.05" max="1" step="0.01" value="' + c.h + '"></div>' +
        '<label class="grp inline"><span>重置</span><input type="checkbox" id="c-reset"></label>',
      onOpen: function (root) {
        var im = new Image();
        im.src = st.src;
        DN.qsa('input[type=range]', root).forEach(function (r) {
          r.addEventListener('input', function () {
            var x = +DN.qs('#c-x', root).value, y = +DN.qs('#c-y', root).value;
            var w = +DN.qs('#c-w', root).value, h = +DN.qs('#c-h', root).value;
            paint(x, y, w, h);
          });
        });
        DN.qs('#c-reset', root).addEventListener('change', function () {
          if (this.checked) {
            DN.qs('#c-x', root).value = 0; DN.qs('#c-y', root).value = 0;
            DN.qs('#c-w', root).value = 1; DN.qs('#c-h', root).value = 1;
            paint(0, 0, 1, 1);
          }
        });
        function paint(x, y, w, h) {
          var box = DN.qs('#crop-prev', root);
          box.innerHTML = '';
          var cvv = document.createElement('canvas');
          cvv.width = 320; cvv.height = Math.min(320, 320 / (w / h * (st.imgW / st.imgH) || 1)) || 200;
          var c2 = cvv.getContext('2d');
          c2.drawImage(im, x * st.imgW, y * st.imgH, w * st.imgW, h * st.imgH, 0, 0, cvv.width, cvv.height);
          box.appendChild(cvv);
        }
        im.onload = function () {
          paint(+DN.qs('#c-x', root).value, +DN.qs('#c-y', root).value,
            +DN.qs('#c-w', root).value, +DN.qs('#c-h', root).value);
        };
      },
      actions: [{ label: '取消', value: null }, { label: '应用', value: 1, primary: true }],
      onClose: function (v, root) {
        if (!v) return;
        var r = DN.qs('#c-reset', root).checked;
        if (r) {
          st.crop = null;
          st.w = Math.min(page().width * 0.7, st.imgW);
          st.h = st.w / st.imgW * st.imgH;
        } else {
          st.crop = {
            x: +DN.qs('#c-x', root).value, y: +DN.qs('#c-y', root).value,
            w: +DN.qs('#c-w', root).value, h: +DN.qs('#c-h', root).value
          };
        }
        save(); S.dirty = true;
        DN.toast('已裁剪');
      }
    });
  }

  // ---------- 页面操作 ----------
  function addPage() {
    var p = page();
    if (!p) return;
    var np = Store.newPage(p.bg, { width: p.width, height: p.height, dark: p.dark });
    S.note.pages.splice(S.page + 1, 0, np);
    S.page++;
    snapshot();
    save();
    fitView();
    syncBar();
  }

  function delPage() {
    if (S.note.pages.length <= 1) return DN.toast('至少保留一页');
    DN.confirm('删除页', '第 ' + (S.page + 1) + ' 页将被删除。', '删除')
      .then(function (ok) {
        if (!ok) return;
        S.note.pages.splice(S.page, 1);
        S.page = Math.max(0, S.page - 1);
        S.undo.length = 0; S.redo.length = 0;
        save(); fitView(); syncBar(); S.dirty = true;
      });
  }

  function dupPage() {
    var p = page();
    if (!p) return;
    var cp = JSON.parse(JSON.stringify(p));
    cp.id = Store.uid('p');
    S.note.pages.splice(S.page + 1, 0, cp);
    S.page++;
    save(); fitView(); syncBar();
    DN.toast('已复制本页');
  }

  function exportPngThis() {
    var p = page();
    if (!p) return;
    return ensureImages().then(function () {
      var c2 = document.createElement('canvas');
      c2.width = p.width; c2.height = p.height;
      Render.drawPage(c2.getContext('2d'), p, p.width, p.height, false);
      c2.toBlob(function (blob) {
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = (S.note.title || 'note').replace(/[\\/:*?"<>|]/g, '_') + '-p' + (S.page + 1) + '.png';
        a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
        DN.toast('已导出 PNG');
      });
    });
  }

  // ---------- 初始化 ----------
  function init() {
    cv = DN.qs('#ed-canvas');
    ctx = cv.getContext('2d');
    wrap = DN.qs('#ed-wrap');

    DN.qs('#ed-rail').innerHTML = railHtml();
    DN.qs('#ed-rail').addEventListener('click', function (e) {
      var b = e.target.closest('[data-tool]');
      if (!b) return;
      S.tool = b.dataset.tool;
      DN.qsa('.rail-btn', this).forEach(function (x) { x.classList.remove('sel'); });
      b.classList.add('sel');
      S.sel = null;
      syncPanel();
      S.dirty = true;
    });

    cv.addEventListener('pointerdown', onDown);
    cv.addEventListener('pointermove', onMove);
    cv.addEventListener('pointerup', onUp);
    cv.addEventListener('pointercancel', onUp);
    cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });

    // 缩放：Ctrl+滚轮 / 触控板双指；平移：滚轮或中键拖动
    wrap.addEventListener('wheel', function (e) {
      e.preventDefault();
      var p = toPage(e.clientX, e.clientY);
      if (e.ctrlKey || e.metaKey) {
        var k = Math.exp(-e.deltaY * 0.0016);
        var ns = Math.max(0.15, Math.min(6, S.scale * k));
        S.tx -= (p.x * ns - p.x * S.scale);
        S.ty -= (p.y * ns - p.y * S.scale);
        S.scale = ns;
      } else {
        S.tx -= e.deltaX; S.ty -= e.deltaY;
      }
      S.dirty = true;
    }, { passive: false });

    wrap.addEventListener('pointerdown', function (e) {
      if (e.button !== 1) return;
      e.preventDefault();
      var sx = e.clientX, sy = e.clientY, tx = S.tx, ty = S.ty;
      function mv(ev) { S.tx = tx + ev.clientX - sx; S.ty = ty + ev.clientY - sy; S.dirty = true; }
      function up() {
        global.removeEventListener('pointermove', mv);
        global.removeEventListener('pointerup', up);
      }
      global.addEventListener('pointermove', mv);
      global.addEventListener('pointerup', up);
    });

    var ro = new ResizeObserver(function () { resize(); });
    ro.observe(wrap);
    resize();

    document.addEventListener('keydown', function (e) {
      if (DN.qs('#view-editor').classList.contains('hidden')) return;
      var typing = /INPUT|TEXTAREA/.test((document.activeElement || {}).tagName || '');
      if (typing) return;
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') {
        e.preventDefault();
        return e.shiftKey ? restore(S.redo, S.undo) : restore(S.undo, S.redo);
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'y') { e.preventDefault(); return restore(S.redo, S.undo); }
      if ((e.key === 'Delete' || e.key === 'Backspace') && S.sel && S.sel.list.length) {
        e.preventDefault();
        var p = page();
        snapshot();
        p.strokes = p.strokes.filter(function (s) { return S.sel.list.indexOf(s) < 0; });
        S.sel = null;
        save(); S.dirty = true;
        return DN.toast('已删除选中笔画');
      }
      if (e.key === ' ' && !(S.panning)) {
        S.panning = true;
        cv.style.cursor = 'grab';
        return;
      }
      var kmap = { 1: 'pen', 2: 'brush', 3: 'highlighter', 4: 'smartPen', 5: 'pencil', r: 'rect', e: 'ellipse', l: 'line', t: 'triangle', a: 'arrow' };
      if (kmap[e.key] && !e.ctrlKey && !e.metaKey) {
        S.tool = kmap[e.key];
        DN.qsa('.rail-btn').forEach(function (x) { x.classList.toggle('sel', x.dataset.tool === S.tool); });
        syncPanel();
      }
    });

    document.addEventListener('keyup', function (e) {
      if (e.key === ' ') { S.panning = false; cv.style.cursor = ''; }
    });

    // 顶栏
    DN.qs('#ed-back').addEventListener('click', function () {
      if (S.note) Store.saveNote(S.note);
      DN.go('home');
      global.Home.render();
    });
    DN.qs('#ed-undo').addEventListener('click', function () { restore(S.undo, S.redo); });
    DN.qs('#ed-redo').addEventListener('click', function () { restore(S.redo, S.undo); });
    DN.qs('#ed-prev').addEventListener('click', function () { if (S.page > 0) { S.page--; S.sel = null; fitView(); syncBar(); S.dirty = true; } });
    DN.qs('#ed-next').addEventListener('click', function () { if (S.page < S.note.pages.length - 1) { S.page++; S.sel = null; fitView(); syncBar(); S.dirty = true; } });
    DN.qs('#ed-addpage').addEventListener('click', addPage);
    DN.qs('#ed-delpage').addEventListener('click', delPage);
    DN.qs('#ed-duppage').addEventListener('click', dupPage);
    DN.qs('#ed-fit').addEventListener('click', fitView);
    DN.qs('#ed-export').addEventListener('click', exportPngThis);
    DN.qs('#ed-title').addEventListener('change', function () {
      if (!S.note) return;
      S.note.title = this.value.trim() || '未命名笔记';
      this.value = S.note.title;
      Store.saveNote(S.note);
    });
    DN.qs('#ed-ai').addEventListener('click', function () { S.panel = S.panel === 'ai' ? 'prop' : 'ai'; syncPanel(); });
    DN.qs('#ed-layers').addEventListener('click', function () { S.panel = S.panel === 'layers' ? 'prop' : 'layers'; syncPanel(); });
    DN.qs('#ed-star').addEventListener('click', function () {
      if (!S.note) return;
      var v = Store.toggleStar(S.note.id);
      DN.qs('#ed-star').classList.toggle('on', v);
      DN.toast(v ? '已收藏' : '已取消收藏');
    });

    DN.qs('#ed-panel').addEventListener('click', function (e) {
      var root = this, b;
      if ((b = e.target.closest('[data-up]'))) {
        var i = +b.dataset.up, p = page();
        if (i < p.strokes.length - 1) {
          snapshot();
          var tmp = p.strokes[i]; p.strokes[i] = p.strokes[i + 1]; p.strokes[i + 1] = tmp;
          save(); S.dirty = true; syncPanel();
        }
        return;
      }
      if ((b = e.target.closest('[data-del-s]'))) {
        snapshot();
        page().strokes.splice(+b.dataset.delS, 1);
        save(); S.dirty = true; syncPanel();
        return;
      }
    });

    requestAnimationFrame(frame);
  }

  function openNote(id, focusAi) {
    var n = Store.note(id);
    if (!n) return;
    DN.go('editor');
    S.note = n;
    S.page = 0;
    S.undo.length = 0; S.redo.length = 0;
    S.sel = null;
    S.panel = focusAi ? 'ai' : 'prop';
    var st = Store.settings();
    S.tool = st.tool || 'smartPen';
    S.color = st.color || PALETTE[0];
    S.size = st.size || 4;
    S.opacity = st.opacity == null ? 1 : st.opacity;
    DN.qs('#ed-star').classList.toggle('on', !!n.starred);
    DN.qs('#view-editor').classList.toggle('left-hand', !!st.leftHand);
    ensureImages();
    resize(); fitView(); syncBar(); syncPanel();
    requestAnimationFrame(frame);
  }

  global.Editor = {
    init: init,
    openNote: openNote,
    hasNote: function () { return !!S.note; },
    applySettings: function () {
      var st = Store.settings();
      DN.qs('#view-editor').classList.toggle('left-hand', !!st.leftHand);
      S.dirty = true;
      syncPanel();
    },
    _state: S
  };
})(window);

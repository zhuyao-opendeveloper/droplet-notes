/* 首页 —— 对应 Android 版 ui/home.dart：
 * 文件夹行（全部/未归档/各文件夹/新建）+ 筛选行（标签/收藏/搜索）+ 笔记卡片网格。
 */
(function (global) {
  'use strict';

  var DN = global.DN, Store = global.Store;
  var state = {
    folder: null,        // null = 全部
    unfiled: false,      // 「未归档」与「全部」的 folderId 都是 null，必须另开字段
    starred: false,
    tag: null,
    keyword: '',
    grid: true
  };

  function folderRowHtml() {
    var fs = Store.folders();
    var chips = ['<button class="chip' + (state.unfiled ? ' sel' : '') + '" data-all="1"' +
      (state.folder == null && !state.unfiled ? ' aria-current="true"' : '') + '>' +
      DN.icon('folder', 16) + '<span>全部</span></button>',
    '<button class="chip' + (state.unfiled ? ' sel' : '') + '" data-unfiled="1">' +
      DN.icon('folder', 16) + '<span>未归档</span></button>'];
    fs.forEach(function (f) {
      chips.push('<button class="chip' + (state.folder === f.id ? ' sel' : '') + '" data-folder="' + f.id +
        '" title="长按可重命名 / 改色 / 删除"><i class="fd" style="background:' +
        (Store.PALETTE[f.color] || Store.PALETTE[0]) + '"></i><span>' + DN.esc(f.name) + '</span></button>');
    });
    chips.push('<button class="chip add" data-newfolder="1">' + DN.icon('add', 16) + '<span>新建文件夹</span></button>');
    return chips.join('');
  }

  function filterRowHtml() {
    var ts = Store.tags();
    // 属性名不能与卡片上的 data-star="<笔记id>" 撞车，否则卡片收藏会被当成筛选按钮
    var h = ['<button class="chip' + (state.starred ? ' sel' : '') + '" data-starfilter="1">' +
      DN.icon('star', 16) + '<span>收藏</span></button>'];
    ts.forEach(function (t) {
      h.push('<button class="chip' + (state.tag === t.name ? ' sel' : '') + '" data-tag="' + DN.esc(t.name) + '">' +
        '<i class="fd" style="background:' + (Store.PALETTE[t.color] || Store.PALETTE[0]) + '"></i>' +
        '<span>' + DN.esc(t.name) + '</span></button>');
    });
    h.push('<button class="chip add" data-newtag="1">' + DN.icon('add', 16) + '<span>新建标签</span></button>');
    return h.join('');
  }

  function emptyHint() {
    if (state.folder) {
      var f = Store.folder(state.folder);
      return '「' + ((f && f.name) || '文件夹') + '」里还没有笔记';
    }
    if (state.unfiled) return '没有未归档的笔记';
    if (state.tag) return '没有带「' + state.tag + '」标签的笔记';
    if (state.starred) return '还没有收藏的笔记';
    if (state.keyword) return '没有匹配「' + state.keyword + '」的笔记';
    return '还没有笔记，点右下角新建';
  }

  function render() {
    var host = DN.qs('#home-folders');
    host.innerHTML = folderRowHtml();
    var f2 = DN.qs('#home-filters');
    f2.innerHTML = filterRowHtml();

    var list = Store.listNotes({
      folderId: state.folder, unfiledOnly: state.unfiled, starredOnly: state.starred,
      tag: state.tag, keyword: state.keyword
    });
    var grid = DN.qs('#home-grid');
    grid.className = 'note-grid' + (state.grid ? '' : ' list');
    if (!list.length) {
      grid.innerHTML = '<div class="empty">' + DN.icon('page', 40) + '<p>' + DN.esc(emptyHint()) + '</p></div>';
      DN.qs('#home-count').textContent = '0 篇';
      return;
    }
    grid.innerHTML = list.map(cardHtml).join('');
    DN.qs('#home-count').textContent = list.length + ' 篇';
    // 封面缩略图：按页坐标渲染，缩放进小画布
    DN.qsa('canvas[data-thumb]', grid).forEach(function (cv) {
      var note = Store.note(cv.dataset.thumb);
      if (!note) return;
      var page = (note.pages || [])[0];
      if (!page) return;
      var ctx = cv.getContext('2d');
      var sx = cv.width / page.width, sy = cv.height / page.height;
      ctx.save();
      ctx.scale(sx, sy);
      global.Render.drawPage(ctx, page, page.width, page.height, false);
      ctx.restore();
    });
  }

  function cardHtml(n) {
    var f = n.folderId ? Store.folder(n.folderId) : null;
    return '<article class="note-card" data-id="' + n.id + '">' +
      '<button class="cover" data-open="' + n.id + '"><canvas data-thumb="' + n.id + '" width="280" height="360"></canvas></button>' +
      '<div class="meta"><div class="title" title="' + DN.esc(n.title) + '">' + DN.esc(n.title) + '</div>' +
      '<div class="sub">' + DN.fmtDate(n.updated) +
      (f ? ' · <i class="inline-fd" style="background:' + (Store.PALETTE[f.color] || Store.PALETTE[0]) +
        '"></i>' + DN.esc(f.name) : '') + '</div></div>' +
      '<div class="acts">' +
      '<button class="icon-btn" data-star="' + n.id + '" title="收藏">' +
      DN.icon(n.starred ? 'star_f' : 'star', 20) + '</button>' +
      '<button class="icon-btn" data-move="' + n.id + '" title="移动到文件夹">' + DN.icon('folder', 20) + '</button>' +
      '<button class="icon-btn" data-export="' + n.id + '" title="导出 PNG">' + DN.icon('download', 20) + '</button>' +
      '<button class="icon-btn" data-more="' + n.id + '" title="更多">' + DN.icon('more', 20) + '</button>' +
      '</div></article>';
  }

  // ---------- 交互 ----------
  function newFolderDialog() {
    var color = 0;
    DN.dialog({
      title: '新建文件夹',
      body: '<label class="field"><span>名称</span><input id="fd-name" type="text" placeholder="例如：专业课"></label>' +
        '<div class="field"><span>颜色</span><div class="swatches" id="fd-colors">' +
        Store.PALETTE.map(function (c, i) {
          return '<button class="sw' + (i === 0 ? ' sel' : '') + '" data-c="' + i + '" style="background:' + c + '"></button>';
        }).join('') + '</div></div>',
      onOpen: function (root) {
        DN.qs('#fd-colors', root).addEventListener('click', function (e) {
          var b = e.target.closest('[data-c]');
          if (!b) return;
          color = +b.dataset.c;
          DN.qsa('.sw', root).forEach(function (s) { s.classList.remove('sel'); });
          b.classList.add('sel');
        });
      },
      actions: [{ label: '取消', value: null }, { label: '创建', value: 1, primary: true }],
      onClose: function (v, root) {
        if (!v) return;
        var name = DN.qs('#fd-name', root).value.trim();
        if (!name) { DN.toast('名称不能为空'); return; }
        Store.createFolder(name, color);
        render();
        DN.toast('已创建「' + name + '」');
      }
    });
  }

  function folderMenu(id) {
    var f = Store.folder(id);
    if (!f) return;
    DN.dialog({
      title: '文件夹：' + f.name,
      body: '<div class="dlg-list">' +
        '<button class="row" data-a="rename">' + DN.icon('edit', 18) + '<span>重命名</span></button>' +
        '<button class="row" data-a="color">' + DN.icon('rainbow', 18) + '<span>更改颜色</span></button>' +
        '<button class="row danger" data-a="del">' + DN.icon('delete', 18) + '<span>删除文件夹</span></button>' +
        '</div>',
      actions: [{ label: '关闭', value: null }],
      onOpen: function (root) {
        root.addEventListener('click', function (e) {
          var b = e.target.closest('[data-a]');
          if (!b) return;
          var a = b.dataset.a;
          var close = DN.qs('.scrim .dialog [data-x]', document);
          setTimeout(function () {
            if (a === 'rename') {
              DN.prompt('重命名文件夹', f.name).then(function (v) {
                if (v) { Store.renameFolder(id, v); render(); }
              });
            } else if (a === 'color') {
              DN.dialog({
                title: '更改颜色',
                body: '<div class="swatches">' + Store.PALETTE.map(function (c, i) {
                  return '<button class="sw' + (i === f.color ? ' sel' : '') + '" data-c="' + i + '" style="background:' + c + '"></button>';
                }).join('') + '</div>',
                onClose: function (v2, root2) {
                  if (!v2) return;
                  var sel = DN.qs('.sw.sel', root2);
                  if (sel) { Store.setFolderColor(id, +sel.dataset.c); render(); }
                }
              });
            } else if (a === 'del') {
              // 删除文件夹只删容器：里面的笔记移回「未归档」
              var inside = Store.listNotes({ folderId: id });
              DN.confirm('删除文件夹', '「' + f.name + '」里有 ' + inside.length +
                ' 篇笔记。删除文件夹本身，这些笔记会移回「未归档」，笔记不会丢。', '删除文件夹')
                .then(function (ok) {
                  if (!ok) return;
                  Store.deleteFolder(id);
                  if (state.folder === id) { state.folder = null; }
                  render();
                  DN.toast('已删除文件夹，' + inside.length + ' 篇笔记移回未归档');
                });
            }
          }, 10);
          if (close) close.click();
        });
      }
    });
  }

  function moveNoteDialog(id) {
    var fs = Store.folders();
    var body = '<div class="dlg-list">' +
      '<button class="row" data-v="__null">' + DN.icon('folder', 18) + '<span>未归档</span></button>' +
      fs.map(function (f) {
        return '<button class="row" data-v="' + f.id + '"><i class="fd" style="background:' +
          (Store.PALETTE[f.color] || Store.PALETTE[0]) + '"></i><span>' + DN.esc(f.name) + '</span></button>';
      }).join('') +
      '<button class="row add" data-v="__new">' + DN.icon('folder_add', 18) + '<span>新建文件夹</span></button>' +
      '</div>';
    DN.dialog({
      title: '移动到文件夹',
      body: body,
      actions: [{ label: '取消', value: null }],
      onOpen: function (root) {
        root.addEventListener('click', function (e) {
          var b = e.target.closest('[data-v]');
          if (!b) return;
          var v = b.dataset.v, node = b;
          setTimeout(function () {
            if (v === '__new') {
              newFolderDialog();
              return;
            }
            Store.moveNote(id, v === '__null' ? null : v);
            render();
            DN.toast('已移动到' + (v === '__null' ? '「未归档」' : '「' + ((Store.folder(v) || {}).name || '') + '」'));
          }, 10);
          var close = node.closest('.dialog').querySelector('[data-x]');
          if (close) close.click();
        });
      }
    });
  }

  function moreMenu(id) {
    DN.dialog({
      title: '笔记操作',
      body: '<div class="dlg-list">' +
        '<button class="row" data-a="rename">' + DN.icon('edit', 18) + '<span>重命名</span></button>' +
        '<button class="row" data-a="dup">' + DN.icon('copy', 18) + '<span>创建副本</span></button>' +
        '<button class="row" data-a="png">' + DN.icon('download', 18) + '<span>导出 PNG</span></button>' +
        '<button class="row" data-a="ai">' + DN.icon('sparkle', 18) + '<span>AI 处理（总结/提纲…）</span></button>' +
        '<button class="row danger" data-a="del">' + DN.icon('delete', 18) + '<span>删除</span></button>' +
        '</div>',
      actions: [{ label: '关闭', value: null }],
      onOpen: function (root) {
        root.addEventListener('click', function (e) {
          var b = e.target.closest('[data-a]');
          if (!b) return;
          var a = b.dataset.a;
          setTimeout(function () {
            var n = Store.note(id);
            if (!n) return;
            if (a === 'rename') {
              DN.prompt('重命名笔记', n.title).then(function (v) { if (v) { n.title = v; Store.saveNote(n); render(); } });
            } else if (a === 'dup') {
              Store.duplicateNote(id); render(); DN.toast('已创建副本');
            } else if (a === 'png') {
              exportPng(id);
            } else if (a === 'ai') {
              global.Editor.openNote(id, true);
            } else if (a === 'del') {
              DN.confirm('删除笔记', '「' + n.title + '」将被删除，且无法恢复。', '删除')
                .then(function (ok) { if (ok) { Store.deleteNote(id); render(); DN.toast('已删除'); } });
            }
          }, 10);
          var close = b.closest('.dialog').querySelector('[data-x]');
          if (close) close.click();
        });
      }
    });
  }

  /** 导出笔记首页为 PNG */
  function exportPng(id) {
    var n = Store.note(id);
    if (!n || !n.pages || !n.pages.length) return;
    var page = n.pages[0];
    var cv = document.createElement('canvas');
    cv.width = page.width; cv.height = page.height;
    global.Render.drawPage(cv.getContext('2d'), page, page.width, page.height, false);
    cv.toBlob(function (blob) {
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = (n.title || 'note').replace(/[\\/:*?"<>|]/g, '_') + '.png';
      a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
      DN.toast('已导出 PNG');
    });
  }

  function newNoteDialog() {
    var bgs = [
      ['blank', '空白', '空白页'],
      ['ruled', '横线', '每行一道横线'],
      ['grid', '网格', '方格纸'],
      ['dot', '点阵', '点格纸'],
      ['cornell', '康奈尔', '线索栏 + 总结区']
    ];
    DN.dialog({
      title: '新建笔记',
      body: '<label class="field"><span>标题</span><input id="nn-title" type="text" placeholder="可以先空着"></label>' +
        '<div class="field"><span>纸张</span><div class="tpl" id="nn-bg">' +
        bgs.map(function (b, i) {
          return '<button class="tp' + (i === 1 ? ' sel' : '') + '" data-bg="' + b[0] + '">' +
            '<canvas width="96" height="128" data-prev="' + b[0] + '"></canvas>' +
            '<span>' + b[1] + '</span><em>' + b[2] + '</em></button>';
        }).join('') + '</div></div>',
      onOpen: function (root) {
        DN.qs('#nn-bg', root).addEventListener('click', function (e) {
          var b = e.target.closest('[data-bg]');
          if (!b) return;
          DN.qsa('.tp', root).forEach(function (x) { x.classList.remove('sel'); });
          b.classList.add('sel');
        });
        // 纸张小预览
        DN.qsa('canvas[data-prev]', root).forEach(function (cv) {
          var ctx = cv.getContext('2d');
          var pg = { bg: cv.dataset.prev, width: 96, height: 128 };
          ctx.save(); ctx.scale(96 / 300, 128 / 400);
          global.Render.drawBackground(ctx, pg, 300, 400, false);
          ctx.restore();
        });
      },
      actions: [{ label: '取消', value: null }, { label: '创建', value: 1, primary: true }],
      onClose: function (v, root) {
        if (!v) return;
        var title = DN.qs('#nn-title', root).value.trim() || '未命名笔记';
        var bg = (DN.qs('.tp.sel', root) || {}).dataset ? DN.qs('.tp.sel', root).dataset.bg : 'ruled';
        // 在哪个文件夹里点新建，新笔记就落在哪个文件夹里
        var n = Store.createBlank({ title: title, bg: bg, folderId: state.folder });
        global.Editor.openNote(n.id);
      }
    });
  }

  function settingsDialog() {
    var s = Store.settings();
    DN.dialog({
      title: '设置',
      wide: true,
      body:
        '<div class="settings">' +
        '<div class="field"><span>主题</span><div class="seg" id="st-theme">' +
        [['light', '浅色'], ['paper', '米黄纸'], ['dark', '深色']].map(function (t) {
          return '<button class="' + (s.theme === t[0] ? 'sel' : '') + '" data-v="' + t[0] + '">' + t[1] + '</button>';
        }).join('') + '</div></div>' +
        '<div class="field"><span>纸张背景</span><div class="seg" id="st-bg"></div></div>' +
        '<label class="field inline"><span>左手模式（工具盘放左边）</span>' +
        '<input type="checkbox" id="st-left"' + (s.leftHand ? ' checked' : '') + '></label>' +
        '<label class="field inline"><span>手绘图形自动识别</span>' +
        '<input type="checkbox" id="st-auto"' + (s.autoShape ? ' checked' : '') + '></label>' +
        '<div class="field"><span>识别宽容度</span><input type="range" id="st-tol" min="0" max="1" step="0.1" value="' + s.shapeTolerance + '">' +
        '<em id="st-tol-v">' + s.shapeTolerance + '</em></div>' +
        '<div class="field"><span>网格/点阵间距</span><input type="range" id="st-grid" min="12" max="64" step="4" value="' + s.gridSize + '">' +
        '<em id="st-grid-v">' + s.gridSize + 'px</em></div>' +
        '<hr><div class="field"><span>AI 接口（网页版专属）</span>' +
        '<input id="ai-url" type="text" value="' + DN.esc(Store.aiConfig().baseUrl) + '" placeholder="https://.../v1">' +
        '</div>' +
        '<div class="field"><span>模型</span><input id="ai-model" type="text" value="' + DN.esc(Store.aiConfig().model) + '"></div>' +
        '<div class="field"><span>API Key（只存本机）</span><input id="ai-key" type="password" value="' + DN.esc(Store.aiConfig().apiKey) + '"></div>' +
        '<p class="hint">走 OpenAI 兼容协议，DeepSeek / 通义 / 智谱 / Moonshot / 硅基流动 / 本地 Ollama 都能用，改地址和模型即可。' +
        '请求由你的浏览器直连该地址，Key 不外传。若报 CORS 错，说明该端点不允许浏览器跨域访问。</p>' +
        '<hr><div class="field"><span>备份</span><div class="row-btns">' +
        '<button class="btn" id="bk-export">导出全部（含文件夹与标签）</button>' +
        '<button class="btn" id="bk-import">从备份恢复</button>' +
        '<button class="btn" id="bk-file-import">导入 .md / .txt 为笔记</button>' +
        '</div><input type="file" id="bk-file" accept=".json,.md,.txt" hidden></div>' +
        '<hr><div class="field"><span>开源</span><div class="row-btns">' +
        '<button class="btn" id="st-repo">仓库地址 · 给个 Star ⭐</button>' +
        '</div><p class="hint">Hydro Note 完全开源（MIT）：免费、无广告、不联网、不收集任何数据。' +
        '如果它对你有用，欢迎到仓库点个 Star —— 这是它继续更新下去的唯一动力。</p></div>' +
        '</div>',
      actions: [{ label: '取消', value: null }, { label: '保存', value: 1, primary: true }],
      onOpen: function (root) {
        var cfg = Store.aiConfig();
        void cfg;
        DN.qs('#st-tol', root).addEventListener('input', function () {
          DN.qs('#st-tol-v', root).textContent = this.value;
        });
        DN.qs('#st-grid', root).addEventListener('input', function () {
          DN.qs('#st-grid-v', root).textContent = this.value + 'px';
        });
        DN.qs('#st-repo', root).addEventListener('click', repoDialog);
        DN.qs('#bk-export', root).addEventListener('click', function () {
          var blob = new Blob([Store.exportAll()], { type: 'application/json' });
          var a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = 'HydroNote-备份-' + new Date().toISOString().slice(0, 10) + '.json';
          a.click();
          DN.toast('已导出备份');
        });
        DN.qs('#bk-import', root).addEventListener('click', function () {
          DN.qs('#bk-file', root).click();
        });
        DN.qs('#bk-file', root).addEventListener('change', function () {
          var f = this.files && this.files[0];
          if (!f) return;
          var fr = new FileReader();
          fr.onload = function () {
            try {
              if (/\.json$/i.test(f.name)) {
                var r = Store.importAll(fr.result, 'merge');
                render();
                DN.toast('已恢复 ' + r.count + ' 篇笔记');
              } else {
                var t = String(fr.result);
                var firstLine = t.split('\n')[0].replace(/^#\s*/, '').slice(0, 40) || f.name;
                var n = Store.createBlank({ title: firstLine });
                n.pages[0].strokes.push({ id: Store.uid('s'), type: 'text', text: t, x: 60, y: 60, size: 18, color: '#1A1A1A', opacity: 1 });
                Store.saveNote(n);
                render();
                DN.toast('已导入为笔记');
              }
            } catch (e) { DN.toast('导入失败：' + e.message); }
          };
          fr.readAsText(f);
          this.value = '';
        });
        // 纸张背景选择（默认稿纸样式）
        var bgs = [['ruled', '横线'], ['grid', '网格'], ['dot', '点阵'], ['blank', '空白'], ['cornell', '康奈尔']];
        DN.qs('#st-bg', root).innerHTML = bgs.map(function (b) {
          return '<button class="' + (s.bg === b[0] ? 'sel' : '') + '" data-v="' + b[0] + '">' + b[1] + '</button>';
        }).join('');
        DN.qsa('.seg', root).forEach(function (seg) {
          seg.addEventListener('click', function (e) {
            var b = e.target.closest('[data-v]');
            if (!b) return;
            DN.qsa('button', seg).forEach(function (x) { x.classList.remove('sel'); });
            b.classList.add('sel');
          });
        });
      },
      onClose: function (v, root) {
        if (!v) return;
        var theme = (DN.qs('#st-theme .sel', root) || {}).dataset || {};
        var bgc = (DN.qs('#st-bg .sel', root) || {}).dataset || {};
        var ns = {
          theme: theme.v || 'light', bg: bgc.v || 'ruled',
          dark: (theme.v || 'light') === 'dark',
          leftHand: DN.qs('#st-left', root).checked,
          autoShape: DN.qs('#st-auto', root).checked,
          shapeTolerance: parseFloat(DN.qs('#st-tol', root).value),
          gridSize: parseInt(DN.qs('#st-grid', root).value, 10),
          tool: s.tool, color: s.color, size: s.size, opacity: s.opacity, pressure: s.pressure
        };
        Store.saveSettings(ns);
        var cfg = Store.aiConfig();
        cfg.baseUrl = DN.qs('#ai-url', root).value.trim();
        cfg.model = DN.qs('#ai-model', root).value.trim();
        cfg.apiKey = DN.qs('#ai-key', root).value.trim();
        Store.saveAI(cfg);
        DN.applyTheme();
        render();
        global.Editor.applySettings();
        DN.toast('已保存');
      }
    });
  }

  /** 开源仓库地址：首页 ⭐ 与设置页「开源」共用，改地址只需改这一处。 */
  var REPO_URL = 'https://github.com/zhuyao-opendeveloper/droplet-notes';

  /** 复制文本：navigator.clipboard 在 file:// 下常被拒，退回 execCommand。 */
  function copyText(t) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).then(function () { DN.toast('仓库地址已复制'); }, fallback);
    } else {
      fallback();
    }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = t;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand('copy');
        DN.toast('仓库地址已复制');
      } catch (e) {
        DN.toast('复制失败，请手动选中地址');
      }
      ta.remove();
    }
  }

  /**
   * 开源仓库 + 求 Star。
   *
   * 本作免费、无广告、不联网、不收集任何数据；没有付费墙也没有遥测，
   * 唯一能支持它继续更新下去的就是仓库的 Star。
   */
  function repoDialog() {
    return DN.dialog({
      title: 'Hydro Note 完全开源',
      body:
        '<p class="dlg-msg">免费、无广告、不联网、不收集任何数据。</p>' +
        '<p class="dlg-msg">如果它对你有用，欢迎到仓库点个 Star —— 这是它继续更新下去的唯一动力。</p>' +
        '<p class="repo-line">' + DN.esc(REPO_URL) + '</p>',
      actions: [
        { label: '知道了', value: null },
        { label: '复制地址', value: 1 },
        { label: '打开仓库', value: 2, primary: true }
      ]
    }).then(function (v) {
      if (v === 1) copyText(REPO_URL);
      if (v === 2) window.open(REPO_URL, '_blank', 'noopener');
    });
  }

  function bind() {
    var root = DN.qs('#view-home');

    // 搜索
    var timer = null;
    DN.qs('#home-search').addEventListener('input', function () {
      clearTimeout(timer);
      var v = this.value;
      timer = setTimeout(function () { state.keyword = v; render(); }, 180);
    });

    DN.qs('#home-star').addEventListener('click', repoDialog);

    root.addEventListener('click', function (e) {
      var t = e.target;
      var b;
      if ((b = t.closest('[data-all]'))) { state.folder = null; state.unfiled = false; return render(); }
      if ((b = t.closest('[data-unfiled]'))) { state.folder = null; state.unfiled = true; return render(); }
      if ((b = t.closest('[data-folder]'))) { state.folder = b.dataset.folder; state.unfiled = false; return render(); }
      if ((b = t.closest('[data-newfolder]'))) return newFolderDialog();
      if ((b = t.closest('[data-newtag]'))) {
        return DN.prompt('新建标签', '', '标签名').then(function (v) {
          if (v) { Store.ensureTag(v); render(); }
        });
      }
      if ((b = t.closest('[data-starfilter]'))) { state.starred = !state.starred; return render(); }
      if ((b = t.closest('[data-star]'))) { Store.toggleStar(b.dataset.star); return render(); }
      if ((b = t.closest('[data-tag]'))) { state.tag = state.tag === b.dataset.tag ? null : b.dataset.tag; return render(); }
      if ((b = t.closest('[data-open]'))) return global.Editor.openNote(b.dataset.open);
      if ((b = t.closest('[data-move]'))) return moveNoteDialog(b.dataset.move);
      if ((b = t.closest('[data-more]'))) return moreMenu(b.dataset.more);
      if ((b = t.closest('[data-export]'))) return exportPng(b.dataset.export);
      if ((b = t.closest('#home-new'))) return newNoteDialog();
      if ((b = t.closest('#home-settings'))) return settingsDialog();
      if ((b = t.closest('#home-view'))) { state.grid = !state.grid; return render(); }
    });

    // 长按文件夹 → 菜单（与手机版「长按进菜单」一致）
    var pressTimer = null;
    root.addEventListener('pointerdown', function (e) {
      var b = e.target.closest('[data-folder]');
      if (!b) return;
      pressTimer = setTimeout(function () { pressTimer = null; folderMenu(b.dataset.folder); }, 550);
    });
    ['pointerup', 'pointercancel', 'pointermove'].forEach(function (ev) {
      root.addEventListener(ev, function () { clearTimeout(pressTimer); pressTimer = null; });
    });
  }

  global.Home = {
    init: function () { bind(); },
    render: render,
    state: state,
    exportPng: exportPng
  };
  // 注册路由：否则带 #home 打开时 DN.go('home') 只切视图、不渲染卡片列表
  DN.route('home', function () { render(); });
})(window);

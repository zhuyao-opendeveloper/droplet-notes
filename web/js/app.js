/* 应用外壳：路由、公共 UI 辅助（图标 / 提示 / 对话框 / 日期）。
 * 两个界面：首页 #view-home（对应 Android ui/home.dart）
 *          编辑器 #view-editor（对应 Android ui/editor.dart）
 */
(function (global) {
  'use strict';

  var DN = global.DN = global.DN || {};

  // ---------- DOM 辅助 ----------
  DN.el = function (html) {
    var t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  };
  DN.qs = function (sel, root) { return (root || document).querySelector(sel); };
  DN.qsa = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
  DN.icon = function (name, size) { return global.ICONS.html(name, size); };

  DN.esc = function (s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  };

  DN.fmtDate = function (ts) {
    var d = new Date(ts || Date.now()), now = new Date();
    var sameDay = d.toDateString() === now.toDateString();
    var p = function (n) { return n < 10 ? '0' + n : '' + n; };
    if (sameDay) return '今天 ' + p(d.getHours()) + ':' + p(d.getMinutes());
    var y = d.getFullYear() === now.getFullYear() ? '' : d.getFullYear() + '/';
    return y + (d.getMonth() + 1) + '/' + d.getDate();
  };

  // ---------- Toast ----------
  var toastTimer = null;
  DN.toast = function (msg, kind) {
    var box = DN.qs('#toast');
    if (!box) {
      box = DN.el('<div id="toast" class="toast"></div>');
      document.body.appendChild(box);
    }
    box.textContent = msg;
    box.className = 'toast show' + (kind ? ' ' + kind : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { box.className = 'toast'; }, 2600);
  };

  // ---------- 对话框 ----------
  /**
   * @param {object} o {title, body(html), wide, actions:[{label,value,primary,danger}], onOpen(root)}
   * @returns Promise —— resolve 被点按钮的 value，关闭为 null
   */
  DN.dialog = function (o) {
    return new Promise(function (resolve) {
      var acts = (o.actions || [{ label: '确定', value: true, primary: true }]);
      var btns = acts.map(function (a, i) {
        return '<button class="btn' + (a.primary ? ' primary' : '') + (a.danger ? ' danger' : '') +
          '" data-i="' + i + '">' + DN.esc(a.label) + '</button>';
      }).join('');
      var dlg = DN.el(
        '<div class="scrim">' +
        '<div class="dialog' + (o.wide ? ' wide' : '') + '">' +
        '<div class="dialog-head"><span>' + DN.esc(o.title || '') + '</span>' +
        '<button class="icon-btn" data-x="1" aria-label="关闭">' + DN.icon('close', 20) + '</button></div>' +
        '<div class="dialog-body">' + (o.body || '') + '</div>' +
        '<div class="dialog-foot">' + btns + '</div>' +
        '</div></div>');
      document.body.appendChild(dlg);
      dlg.addEventListener('click', function (e) {
        if (e.target === dlg) return close(null);
        var x = e.target.closest('[data-x]');
        if (x) return close(null);
        var b = e.target.closest('[data-i]');
        if (b) return close(acts[+b.dataset.i].value);
      });
      function close(v) {
        var a = acts.slice();
        if (typeof o.onClose === 'function') o.onClose(v, DN.qs('.dialog-body', dlg));
        dlg.remove();
        resolve(v);
        void a;
      }
      if (typeof o.onOpen === 'function') o.onOpen(DN.qs('.dialog-body', dlg), close);
      var f = DN.qs('input,textarea,select', dlg);
      if (f) setTimeout(function () { f.focus(); }, 30);
    });
  };

  DN.confirm = function (title, msg, okLabel) {
    return DN.dialog({
      title: title,
      body: '<p class="dlg-msg">' + DN.esc(msg) + '</p>',
      actions: [{ label: '取消', value: false }, { label: okLabel || '确定', value: true, danger: true }]
    });
  };

  DN.prompt = function (title, value, label) {
    return DN.dialog({
      title: title,
      body: '<label class="field"><span>' + DN.esc(label || '名称') + '</span>' +
        '<input type="text" id="dlg-input" value="' + DN.esc(value || '') + '"></label>',
      onOpen: function (root) { var i = DN.qs('#dlg-input', root); i.select(); },
      onClose: function (v, root) { if (v) v.value = DN.qs('#dlg-input', root).value.trim(); },
      actions: [{ label: '取消', value: null }, { label: '确定', value: {}, primary: true }]
    }).then(function (v) { return v ? v.value : null; });
  };

  // ---------- 路由 ----------
  var routes = {}, current = null;
  DN.route = function (name, fn) { routes[name] = fn; };
  DN.go = function (name, arg) {
    DN.qsa('.view').forEach(function (v) { v.classList.add('hidden'); });
    var host = DN.qs('#view-' + name);
    if (host) host.classList.remove('hidden');
    if (location.hash !== '#' + name) location.hash = '#' + name;
    current = name;
    if (routes[name]) routes[name](arg);
  };

  // ---------- 主题 ----------
  function applyTheme() {
    var s = global.Store.settings();
    var dark = s.dark || s.theme === 'dark';
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : (s.theme === 'paper' ? 'paper' : 'light'));
  }
  DN.applyTheme = applyTheme;

  function navTo(name) {
    if (name === current) return;   // 已经在目标页就别重跑路由，否则会把编辑器状态清掉
    DN.go(name === 'editor' ? 'editor' : 'home');
  }

  global.addEventListener('DOMContentLoaded', function () {
    applyTheme();
    global.Home.init();
    global.Editor.init();
    var hash = (location.hash || '').replace('#', '');
    // 刷新时会带着上次的 #editor，但「当前打开的笔记」不落盘，
    // 直接进编辑器就是个空壳（工具栏都在，画不了也没东西可画）—— 回首页更合理
    if (hash === 'editor' && !global.Editor.hasNote()) hash = 'home';
    navTo(hash);
    ICONS.paint(document);
    global.addEventListener('hashchange', function () {
      navTo((location.hash || '').replace('#', ''));
    });
  });
})(window);

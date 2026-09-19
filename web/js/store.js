/* 数据层 —— 与 Android 版 storage/note_store.dart + data/folders.dart + data/tags.dart 对齐。
 *
 * 手机上标签/文件夹定义存在 SharedPreferences、笔记本体在 notes 目录；
 * 网页版统一放 localStorage：
 *   droplet.notes    笔记全集（含 pages / strokes）
 *   droplet.folders  文件夹定义
 *   droplet.tags     标签定义
 *   droplet.settings 外观与工具偏好
 *   droplet.ai       AI 配置（地址 / 模型 / Key）——只存本机，不随笔记导出
 *
 * 备份：导出 JSON 时把 folders/tags/settings 一起写进 `_meta` 字段，
 * 否则恢复回来只有笔记没有文件夹 —— Android 版踩过一模一样的坑
 * （见 backup.dart 里的 _meta.json 注释）。
 */
(function (global) {
  'use strict';

  var K = {
    notes: 'droplet.notes',
    folders: 'droplet.folders',
    tags: 'droplet.tags',
    settings: 'droplet.settings',
    ai: 'droplet.ai'
  };

  // 文件夹 / 标签配色（与 Android TagStore.palette 同色值）
  var PALETTE = ['#3B5BDB', '#00897B', '#2E7D32', '#7B1FA2', '#D81B60', '#FF8F00', '#455A64', '#6D4C41'];

  function read(key, def) {
    try {
      var s = localStorage.getItem(key);
      return s ? JSON.parse(s) : def;
    } catch (e) {
      console.warn('read failed', key, e);
      return def;
    }
  }

  function write(key, val) {
    try {
      localStorage.setItem(key, JSON.stringify(val));
      return true;
    } catch (e) {
      // localStorage 满了（笔记里图片/笔迹过多）是最常见的失败原因
      console.error('write failed', key, e);
      return false;
    }
  }

  function uid(p) {
    return (p || 'n') + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  }

  var _notes = null, _folders = null, _tags = null;

  function notes() {
    if (!_notes) _notes = read(K.notes, []) || [];
    return _notes;
  }
  function folders() {
    if (!_folders) _folders = read(K.folders, []) || [];
    return _folders;
  }
  function tags() {
    if (!_tags) _tags = read(K.tags, []) || [];
    return _tags;
  }

  function persistNotes() { return write(K.notes, notes()); }
  function persistFolders() { return write(K.folders, folders()); }
  function persistTags() { return write(K.tags, tags()); }

  // ---------- 笔记 ----------
  function newPage(bg, opts) {
    opts = opts || {};
    return {
      id: uid('p'),
      bg: bg || 'ruled',
      width: opts.width || 1200,
      height: opts.height || 1600,
      dark: !!opts.dark,
      strokes: []
    };
  }

  function createBlank(opts) {
    opts = opts || {};
    var t = Date.now();
    var n = {
      id: uid('n'),
      title: opts.title || '未命名笔记',
      created: t,
      updated: t,
      folderId: opts.folderId || null,
      tags: opts.tags || [],
      starred: false,
      coverIndex: 0,
      pages: [newPage(opts.bg || 'ruled')]
    };
    notes().unshift(n);
    persistNotes();
    return n;
  }

  function note(id) {
    var a = notes();
    for (var i = 0; i < a.length; i++) if (a[i].id === id) return a[i];
    return null;
  }

  function saveNote(n) {
    var a = notes(), i;
    n.updated = Date.now();
    for (i = 0; i < a.length; i++) if (a[i].id === n.id) { a[i] = n; return persistNotes(); }
    a.unshift(n);
    return persistNotes();
  }

  function deleteNote(id) {
    var a = notes();
    for (var i = 0; i < a.length; i++) {
      if (a[i].id === id) { a.splice(i, 1); return persistNotes(); }
    }
    return false;
  }

  function duplicateNote(id) {
    var src = note(id);
    if (!src) return null;
    var copy = JSON.parse(JSON.stringify(src));
    copy.id = uid('n');
    copy.title = src.title + ' 副本';
    copy.created = Date.now();
    copy.updated = copy.created;
    copy.pages = (copy.pages || []).map(function (p) { p.id = uid('p'); return p; });
    notes().unshift(copy);
    persistNotes();
    return copy;
  }

  /*
   * 列表筛选。
   *
   * folderId 与 unfiledOnly 必须是两个独立参数：
   * 「未归档」和「不过滤」的 folderId 都是 null，合成一个字段没法区分
   * （Android 版 home.dart 同款设计）。
   */
  function listNotes(opt) {
    opt = opt || {};
    var kw = (opt.keyword || '').trim().toLowerCase();
    return notes().filter(function (n) {
      if (opt.folderId != null && n.folderId !== opt.folderId) return false;
      if (opt.unfiledOnly && n.folderId != null) return false;
      if (opt.starredOnly && !n.starred) return false;
      if (opt.tag && (n.tags || []).indexOf(opt.tag) < 0) return false;
      if (kw) {
        var inTitle = (n.title || '').toLowerCase().indexOf(kw) >= 0;
        if (!inTitle) {
          // 全文匹配：正文只有文本框和标签，取文本元素的字符串
          var body = [];
          (n.pages || []).forEach(function (p) {
            (p.strokes || []).forEach(function (s) {
              if (s.type === 'text') body.push(s.text || '');
            });
          });
          if (body.join('\n').toLowerCase().indexOf(kw) < 0) return false;
        }
      }
      return true;
    }).sort(function (a, b) { return (b.updated || 0) - (a.updated || 0); });
  }

  function moveNote(id, folderId) {
    var n = note(id);
    if (!n) return false;
    n.folderId = folderId;   // null = 移出文件夹，回到「未归档」
    return saveNote(n);
  }

  function toggleStar(id) {
    var n = note(id);
    if (!n) return false;
    n.starred = !n.starred;
    saveNote(n);
    return n.starred;
  }

  // ---------- 文件夹 ----------
  function createFolder(name, color) {
    var f = {
      id: uid('f'),
      name: name || '新建文件夹',
      color: color == null ? 0 : color   // PALETTE 下标
    };
    folders().push(f);
    persistFolders();
    return f;
  }

  function renameFolder(id, name) {
    var a = folders();
    for (var i = 0; i < a.length; i++) if (a[i].id === id) { a[i].name = name; return persistFolders(); }
    return false;
  }

  function setFolderColor(id, color) {
    var a = folders();
    for (var i = 0; i < a.length; i++) if (a[i].id === id) { a[i].color = color; return persistFolders(); }
    return false;
  }

  /** 删除文件夹：只删容器，里面的笔记移回「未归档」。删的是容器不是内容。 */
  function deleteFolder(id) {
    var a = folders();
    for (var i = 0; i < a.length; i++) {
      if (a[i].id === id) {
        a.splice(i, 1);
        persistFolders();
        listNotes({ folderId: id }).forEach(function (n) { moveNote(n.id, null); });
        return true;
      }
    }
    return false;
  }

  function folder(id) {
    var a = folders();
    for (var i = 0; i < a.length; i++) if (a[i].id === id) return a[i];
    return null;
  }

  // ---------- 标签 ----------
  function ensureTag(name) {
    var a = tags();
    for (var i = 0; i < a.length; i++) if (a[i].name === name) return a[i];
    var t = { id: uid('t'), name: name, color: a.length % PALETTE.length };
    a.push(t);
    persistTags();
    return t;
  }

  // ---------- 备份 / 恢复 ----------
  function exportAll() {
    return JSON.stringify({
      format: 'droplet-notes-backup',
      version: 1,
      exportedAt: new Date().toISOString(),
      _meta: { folders: folders(), tags: tags(), settings: read(K.settings, {}) },
      notes: notes()
    }, null, 2);
  }

  /** @param {'merge'|'replace'} mode */
  function importAll(text, mode) {
    var d = JSON.parse(text);
    if (!d || !d.notes) throw new Error('不是有效的备份文件');
    var mode2 = mode || 'merge';
    if (mode2 === 'replace') {
      _notes = d.notes;
    } else {
      var seen = {};
      notes().forEach(function (n) { seen[n.id] = 1; });
      (d.notes || []).forEach(function (n) {
        if (seen[n.id]) {
          // 同 id 保留较新的一份
          for (var i = 0; i < _notes.length; i++) {
            if (_notes[i].id === n.id && (n.updated || 0) > (_notes[i].updated || 0)) { _notes[i] = n; break; }
          }
        } else {
          _notes.push(n);
        }
      });
    }
    // 定义必须一起恢复，否则恢复完 folderId 还在、文件夹却没了，
    // 首页上一批笔记就像「凭空消失」
    if (d._meta) {
      if (d._meta.folders) { _folders = d._meta.folders; persistFolders(); }
      if (d._meta.tags) { _tags = d._meta.tags; persistTags(); }
    }
    persistNotes();
    return { count: (d.notes || []).length };
  }

  // ---------- 设置 ----------
  function settings() {
    return read(K.settings, {
      theme: 'light',        // light | dark | paper
      dark: false,
      leftHand: false,
      gridSize: 24,
      shapeTolerance: 0.5,
      autoShape: true,
      pressure: true,
      tool: 'smartPen',
      color: '#3B5BDB',
      size: 4,
      opacity: 1
    });
  }
  function saveSettings(s) { return write(K.settings, s); }

  function aiConfig() {
    return read(K.ai, {
      provider: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      apiKey: '',
      temperature: 0.5,
      systemPrompt: '你是水滴笔记里的写作助手。回答用中文，简洁、准确，直接给结果，不要寒暄。'
    });
  }
  function saveAI(c) { return write(K.ai, c); }

  global.Store = {
    PALETTE: PALETTE,
    uid: uid,
    newPage: newPage,
    notes: notes, folders: folders, tags: tags,
    note: note, saveNote: saveNote, deleteNote: deleteNote, duplicateNote: duplicateNote,
    createBlank: createBlank, listNotes: listNotes, moveNote: moveNote, toggleStar: toggleStar,
    createFolder: createFolder, renameFolder: renameFolder, setFolderColor: setFolderColor,
    deleteFolder: deleteFolder, folder: folder,
    ensureTag: ensureTag,
    exportAll: exportAll, importAll: importAll,
    settings: settings, saveSettings: saveSettings,
    aiConfig: aiConfig, saveAI: saveAI
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = global.Store;
})(typeof window !== 'undefined' ? window : globalThis);

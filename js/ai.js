/* AI 助手 —— 网页版专属能力（手机版没有）。
 *
 * 走 OpenAI 兼容协议（/chat/completions），所以 OpenAI、DeepSeek、通义、
 * 月之暗面、智谱、硅基流动、本地 Ollama / LM Studio 都能用 —— 只要改
 * 「接口地址 + 模型名 + Key」三个框。
 *
 * Key 只存在本机 localStorage，不随笔记导出、不上传任何第三方服务器
 * （请求是浏览器直连你在设置里填的那个地址）。
 *
 * 注意浏览器有同源策略：接口必須支持 CORS。大部分国产大模型公开端点都允许，
 * OpenAI 官方也允许（浏览器直连）。自建 / 本地服务若报 CORS 错，
 * 属于服务端未放开，需要给它加 `Access-Control-Allow-Origin`。
 */
(function (global) {
  'use strict';

  /** 把整篇笔记转成给模型的文本上下文 */
  function noteToText(note, opt) {
    opt = opt || {};
    var out = ['# ' + (note.title || '未命名笔记')];
    (note.pages || []).forEach(function (p, pi) {
      if ((note.pages || []).length > 1) out.push('\n--- 第 ' + (pi + 1) + ' 页 ---');
      (p.strokes || []).forEach(function (s) {
        if (s.type === 'text' && s.text) out.push(String(s.text).replace(/\s+$/, ''));
      });
    });
    var txt = out.join('\n');
    var max = opt.maxChars || 6000;
    if (txt.length > max) txt = txt.slice(0, max) + '\n…（已截断）';
    return txt;
  }

  /** 页面里有没有可喂给模型的内容 */
  function hasText(note) {
    var n = 0;
    (note.pages || []).forEach(function (p) {
      (p.strokes || []).forEach(function (s) { if (s.type === 'text' && s.text) n += s.text.length; });
    });
    return n;
  }

  var PRESETS = [
    { key: 'summary', icon: 'sparkle', label: '总结', hint: '提炼笔记要点',
      prompt: '请阅读下面的笔记内容，输出一份结构化总结：\n1. 一句话概括\n2. 关键要点（3-6 条，每条一行）\n3. 结论/待办（如有）\n\n' },
    { key: 'outline', icon: 'list', label: '提纲', hint: '生成文章大纲',
      prompt: '请根据下面的笔记内容生成一份写作提纲，要求层级清晰（一/（一）/1.），可直接照着写：\n\n' },
    { key: 'polish', icon: 'edit', label: '润色', hint: '改写得更通顺',
      prompt: '请润色下面的文字，保持原意与作者语气，修正语病、统一术语，让它更通顺易读。只输出润色后的正文，不要解释：\n\n' },
    { key: 'expand', icon: 'page_add', label: '续写', hint: '接着往下写',
      prompt: '请接着下面的内容自然续写 2-3 段，保持同样的风格与叙述视角。只输出续写部分：\n\n' },
    { key: 'action', icon: 'check', label: '待办', hint: '提取行动项',
      prompt: '请从下面的笔记里提取所有待办/行动项，每条一行，格式「- [ ] 事项（负责人/时间，若文中提到）」。没有就回答「无」：\n\n' },
    { key: 'quiz', icon: 'tag', label: '出题', hint: '生成复习题',
      prompt: '请根据下面的笔记内容出 5 道复习题（选择/简答混合），并在最后附上答案区。题目要能覆盖核心概念：\n\n' },
    { key: 'translate', icon: 'laser', label: '英译', hint: '中英互译',
      prompt: '请把下面的内容做中英互译（中文译成英文、英文译成中文），保持段落结构，只输出译文：\n\n' }
  ];

  function endpoint(base) {
    base = (base || '').replace(/\/+$/, '');
    if (/\/chat\/completions$/.test(base)) return base;
    return base + '/chat/completions';
  }

  /**
   * 调用模型。
   * @param {object} o {messages, onDelta, onDone, onError, signal, temperature, cfg}
   */
  function chat(o) {
    var cfg = o.cfg || global.Store.aiConfig();
    if (!cfg.apiKey) {
      o.onError && o.onError(new Error('还没有配置 API Key —— 点左上角 ⚙ 设置里填一下（只存在你本机）'));
      return Promise.reject(new Error('no key'));
    }
    var url = endpoint(cfg.baseUrl);
    var body = {
      model: cfg.model,
      messages: o.messages,
      temperature: o.temperature != null ? o.temperature : cfg.temperature,
      stream: !!o.onDelta
    };
    return fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + cfg.apiKey
      },
      body: JSON.stringify(body),
      signal: o.signal
    }).then(function (resp) {
      if (!resp.ok) {
        return resp.text().then(function (t) {
          var msg = 'HTTP ' + resp.status;
          try {
            var j = JSON.parse(t);
            msg = (j.error && (j.error.message || j.error.code)) || j.message || msg;
          } catch (e) {
            if (t) msg += ' ' + t.slice(0, 160);
          }
          throw new Error(msg);
        });
      }
      if (!o.onDelta) {
        return resp.json().then(function (j) {
          var txt = (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || '';
          o.onDone && o.onDone(txt);
          return txt;
        });
      }
      // SSE 流式：data: {...} 逐行来。要自己攒 buffer，
      // 一次 chunk 里可能含多行，也可能一行被切成两半 —— 不能假设一个 chunk 就是一整行，
      // 所以攒够再按行切，尾巴留在 buf 里等下一帧。
      var reader = resp.body.getReader(), dec = new TextDecoder('utf-8'), buf = '', full = '';
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) {
            o.onDone && o.onDone(full);
            return full;
          }
          buf += dec.decode(r.value, { stream: true });
          var lines = buf.split('\n');
          buf = lines.pop();
          for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim();
            if (!ln || ln.indexOf('data:') !== 0) continue;
            var payload = ln.slice(5).trim();
            if (payload === '[DONE]') { o.onDone && o.onDone(full); return full; }
            try {
              var j2 = JSON.parse(payload);
              var d = j2.choices && j2.choices[0] && (j2.choices[0].delta || {});
              if (d.content) { full += d.content; o.onDelta(d.content); }
            } catch (e) { /* 心跳注释行等非 JSON，忽略 */ }
          }
          return pump();
        });
      }
      return pump();
    }).catch(function (err) {
      if (err && err.name === 'AbortError') { o.onDone && o.onDone(''); return ''; }
      // 浏览器里 fetch 失败最常见就是 CORS / 网络，给人话提示
      var m = String(err.message || err);
      if (/Failed to fetch|NetworkError|Load failed/i.test(m)) {
        m = '请求发不出去：多半是接口没放开跨域（CORS），或者地址填错了。'
          + '换一个支持 CORS 的端点试试，或在设置里核对接口地址。';
      }
      o.onError && o.onError(new Error(m));
      throw err;
    });
  }

  /** 走一个预设动作：把笔记正文拼进 prompt 后发给模型 */
  function runPreset(key, note, extra) {
    var p = null;
    for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].key === key) p = PRESETS[i];
    var cfg = global.Store.aiConfig();
    var q = (extra && extra.question) ? extra.question : '';
    if (key === 'ask') {
      if (!q) return Promise.reject(new Error('先写下你的问题'));
      return chat({
        cfg: cfg,
        messages: [
          { role: 'system', content: cfg.systemPrompt },
          { role: 'user', content: '这是我正在写的笔记：\n\n' + noteToText(note) + '\n\n我的问题：' + q }
        ],
        onDelta: extra.onDelta, onDone: extra.onDone, onError: extra.onError, signal: extra.signal
      });
    }
    if (!p) return Promise.reject(new Error('未知动作：' + key));
    return chat({
      cfg: cfg,
      messages: [
        { role: 'system', content: cfg.systemPrompt },
        { role: 'user', content: p.prompt + noteToText(note) }
      ],
      onDelta: extra.onDelta, onDone: extra.onDone, onError: extra.onError, signal: extra.signal
    });
  }

  global.AI = {
    PRESETS: PRESETS,
    chat: chat,
    runPreset: runPreset,
    noteToText: noteToText,
    hasText: hasText,
    endpoint: endpoint
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = global.AI;
})(typeof window !== 'undefined' ? window : globalThis);

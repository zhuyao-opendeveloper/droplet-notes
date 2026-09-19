# Hydro Note · 开源手写笔记

一个开源的手写笔记应用，Android 与 Web 双端同源：**同一套工具、同一套图标、同一套笔迹算法**，网页版额外带 AI 助手。

- 网页版在线用：<https://zhuyao-opendeveloper.github.io/droplet-notes/>
- Android：仓库 `android/` 目录是完整 Flutter 工程，GitHub Actions 自动构建 APK

---

## 它能干什么

### 书写
19 种工具，矢量笔迹（不是位图涂抹，随时可继续编辑、可导出矢量 PDF）：

| 分类 | 工具 |
| --- | --- |
| 笔 | 钢笔、画笔、荧光笔、铅笔、彩虹笔、矢量笔、**智能钢笔**、胶带笔 |
| 擦除 | 橡皮、只擦荧光笔、圈选擦 |
| 图形 | 直线、矩形、椭圆、三角形、箭头 |
| 其他 | 套索、文本、图片、裁剪 |

**智能钢笔**是本项目的特色笔型：笔宽随书写速度反向变化（慢 → 粗，快 → 细），
沿中心线按 45% 半径间距盖一串圆点合成一条路径，起笔顿、收笔出锋，
圆润无尖峰。算法见 `web/js/zmath.js`（JS）与 `android/lib/engine/z_math.dart`（Dart），两边逐行对应。

### 手绘图形识别（长按才触发，只认三类）

**怎么触发**：画完之后**不提笔、停留约 0.5 秒**才识别；抬笔不会自动识别。
识别出来之后手指可以继续拖着改，形状跟着手指走，**抬笔才最终吸附**。

之所以改成这样：早先是抬笔就识别，结果随手写个字也会被拉成某个形状，
识别错了比不识别更烦人。

**只认三种**：

| 类别 | 说明 |
| --- | --- |
| 直线 | 自动吸附到水平 / 垂直 / 45° |
| 圆 | 统一规整成**正圆**（不是任意椭圆） |
| 曲线 | 把抖动粗糙的手绘整合成**光滑无噪点**的曲线 |

曲线平滑是三步走：RDP 简化（保留真拐点）→ Chaikin 切角 → 三点加权平均去噪。
顺序不能换，跳过 RDP 直接平滑会把方角磨圆、整个形状走样。

底层判定仍只用 4 个几何度量：圆度、矩形度、三角度、
**绕行系数**（路径长 ÷ 凸包周长，> 1.45 判为涂鸦 —— 这是唯一能把涂鸦和圆分开的判据）。
可在设置里开关并调宽容度。

### 组织
文件夹 / 标签 / 收藏 / 搜索（含手写 OCR 索引，Android 端）/ 网格与列表两种视图 /
5 种纸张模板（空白、横线、网格、点阵、康奈尔）/ 三套主题（浅色、米黄纸、深色）/ 左手模式。

### 数据
全部存在本机（Android 内部存储 / 浏览器 localStorage），**不上传任何服务器**。
支持 JSON 全量备份导出与恢复（含文件夹、标签、设置的定义），可导入 md/txt。

---

## 网页版

### 直接打开
把仓库拉下来，双击 `web/index.html` 就能用（纯静态，无需构建、无需服务器）。

### AI 功能
网页版比手机端多一个 AI 面板（右上角 ✨ 按钮），内置 7 个预设动作：

总结要点 / 生成大纲 / 润色文字 / 扩写内容 / 提取待办 / 生成测验 / 翻译

外加自由提问。结果可一键复制或插入到当前页。

配置方法：设置 → AI，填 **Base URL / 模型 / API Key**。
走 OpenAI 兼容协议（`/chat/completions`），所以 OpenAI、DeepSeek、月之暗面、通义、智谱，
以及本地的 Ollama、LM Studio 都能用。流式输出，可随时停止。

> API Key 只存在浏览器 localStorage 里，不会发往除你填写的接口之外的任何地方。
> 浏览器有同源策略，接口必须放开 CORS；本地 Ollama 需加 `OLLAMA_ORIGINS=*`。

---

## 目录结构

```
droplet-notes/
├─ web/                 网页版（纯静态）
│  ├─ index.html
│  ├─ css/app.css       三主题 CSS 变量
│  ├─ js/
│  │  ├─ icons.js       58 个 Fluent 图标内联 SVG（与手机端同源）
│  │  ├─ zmath.js       智能钢笔笔迹引擎
│  │  ├─ recognizer.js  手绘图形识别
│  │  ├─ store.js       localStorage 数据层
│  │  ├─ render.js      Canvas 渲染（与 Android 绘制分支一一对应）
│  │  ├─ ai.js          OpenAI 兼容 + SSE 流式
│  │  ├─ app.js/home.js/editor.js
│  └─ tests/            node 单测（ZMath + 图形识别）
└─ android/             Flutter 工程（Android）
   └─ lib/engine/z_math.dart 智能钢笔 Dart 实现
```

## 测试

```bash
cd web
node tests/logic.test.js
```

覆盖智能钢笔 9 条断言（含「中心线无缺口」「宽度限速生效」这类防回归项）
和图形识别 24 例 × 3 档宽容度的基准比对。

## 构建 Android APK

`android/` 下 push 到 main 即触发 GitHub Actions，产物发布在 `dist` 分支。

## 许可

MIT（见 `LICENSE`）。图标来自微软 [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons)（MIT）。

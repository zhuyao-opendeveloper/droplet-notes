# Notein 手写引擎架构深度分析
> 用途：作为自研 **Hydro Notes** 手写笔记 App 的参考蓝本
> 数据来源：逆向源码（com.orion.notein / com.orion.penkit）+ 官方帮助中心 help.note-in.com 双源互证
> 说明：本文档用于**学习参考界面逻辑与笔迹渲染算法结构**，非直接复制其代码，请自行重新实现。

---

## 1. 总体架构分层

```
┌─────────────────────────────────────────────┐
│  UI 层  com.orion.notein                   │
│  noteeditor / richeditor / toolbox /      │
│  colorpicker / notelist / backup ...      │
├─────────────────────────────────────────────┤
│  页面模型层  domain.models.page           │
│  INoteinDisplayItem (页面内容项接口)       │
│  PageLayer / PageGrid / HyperLink / Quote  │
├─────────────────────────────────────────────┤
│  手写引擎核心  com.orion.penkit           │
│  DrawRecord (OooO0O0) / render/eraser/     │
│  lasso / Shape / models(保留类)            │
├─────────────────────────────────────────────┤
│  输入预测  Google Ink 输入预测管线         │
│  SinglePointerPredictor + 平滑缓冲         │
│  pressure/速度归一化 (0.1 / 0.18 系数)     │
├─────────────────────────────────────────────┤
│  基础设施：Room 数据库 / Opencv / Aspose(PDF)
│  Lottie 动画 / Hilt DI                     │
└─────────────────────────────────────────────┘
```

**核心理念**：笔记页 = `INoteinDisplayItem` 集合。任意内容项（手写 Shape、超链、引用块）都实现同一个接口，统一支持区域加载（`isRegionLoadable`）、局部重绘（`getBoundingBox` 缩放）。penkit 是**通用矢量图形引擎**，手写 + 图形 + 套索统一抽象为 Shape，统一 render / erase / lasso。

---

## 2. 核心数据结构（来自逆向保留类）

这些是 R8 混淆后仍保留真实类名的**公开 API 模型**，可作为数据设计参考：

### 2.1 LayerInfo — 图层信息
```kotlin
data class LayerInfo(
    val id: String,          // 图层 ID
    val noteId: String,      // 所属笔记 ID
    val visible: Boolean,    // 是否显示
    val activated: Boolean,  // 是否为当前激活图层
    val extras: String?      // 扩展字段(JSON)
) {
    companion object {
        const val DEFAULT_LAYER_ID = "default"        // 默认内容层
        const val NONE_LAYER_ID = "none"
        const val PAPER_THEME_LAYER_ID = "paper_theme" // 底纸层
        const val UNSPECIFIED_LAYER_ID = "unspecified"
    }
}
```
**默认图层体系**：`paper_theme`（底纸/纸张主题层）+ `default`（内容层）两层起步。

### 2.2 Line — 两点线段
```kotlin
data class Line(val a: PointF, val b: PointF)
```
用于辅助线、规整图形等两点构成元素。

### 2.3 AssistPoint<T> / IntPoint — 泛型坐标点
```kotlin
interface AssistPoint<T : Number> { val x: T; val y: T }
data class IntPoint(override val x: Int, override val y: Int) : AssistPoint<Int>
```
坐标用泛型统一 int/float 两套精度。

### 2.4 TypedRect<T> — 泛型矩形（带中心点）
```kotlin
data class TypedRect<T : Number>(
    val left: T, val top: T, val right: T, val bottom: T,
    val center: Pair<T, T>   // 缓存中心，避免重复计算
)
```
**设计要点**：矩形缓存 center 字段，加速命中测试/选中框绘制。

### 2.5 LassoParams — 套索参数
```kotlin
data class LassoParams(
    val selectedItems: List<DrawRecord>, // 命中选中的内容项
    val border: RectF,                   // 包围盒(AABB)
    val polygonBorder: List<PointF>?     // 套索多边形路径
) {
    fun getContextMenuPos(): Point  // 右键菜单定位在选框顶部中央
}
```
**设计要点**：
- 既存 AABB（`border`）又存任意多边形（`polygonBorder`），支持不规则套索，同时用 AABB 加速粗筛。
- 右键菜单默认显示在选框**顶部中央**。

### 2.6 DrawRecord（混淆名 OooO0O0）— 单笔/单图形记录
构造字段顺序：`id(String)` → `itemType(-1)` → `color(默认黑 -16777216)` → `float` → `ArrayList<点>` → `RectF(边界)` → `float 384(墨迹宽度/采样常量)` → `boolean` → `null`

核心方法：`getBoundingBox` / `onEraserEvent(擦除)` / `onLassoEvent(套索)` / `render` / `offset` / `scale` / `deepCopy` / `getLayerId`

**结构还原（合理推断）**：
```kotlin
class DrawRecord(
    val id: String,
    var itemType: Int = -1,        // -1=手写笔迹, 其他=图形/贴纸等
    var color: Int = Color.BLACK,
    var width: Float = DEFAULT,    // 笔宽
    val points: ArrayList<PointF>, // 笔画采样点序列
    var bounds: RectF,             // 缓存包围盒，局部重绘用
    var tapeLike: Boolean = false, // 胶带笔模式
    val layerId: String? = null    // 归属图层
) {
    fun render(canvas: Canvas, viewMatrix: Matrix)
    fun onEraserEvent(points, size, mode)  // 擦除三模式
    fun onLassoEvent(rect: RectF): Boolean // 是否被套索框选
    fun offset(dx: Float, dy: Float)
    fun scale(sx: Float, sy: Float, pivotX: Float, pivotY: Float)
    fun deepCopy(): DrawRecord
}
```

---

## 3. 手写笔迹渲染算法

### 3.1 输入预测管线（Google Ink）
```
原始触点 → SinglePointerPredictor(运动模型外推"跟手"预测) → 平滑缓冲
        → pressure/速度 归一化 → 采样点序列
```
- **跟手预测**：用运动模型外推下一个预测点，补偿触屏/渲染延迟，实现"低延迟跟手"。
- **平滑缓冲**：进入缓冲队列再输出，过滤抖动。
- **压力归一化系数 0.1 / 0.18**：压力值/速度参与笔宽调制（有压感笔时用压力，无压感笔时用速度模拟）。

### 3.2 笔迹美化思路（Hydro Notes 可用）
参考业界成熟方案（tldraw 的 `perfect-freehand`，MIT 许可）：

```javascript
// 骨架：压力→笔宽 + 速度→笔宽 的动态压实线
import { getStroke } from 'perfect-freehand'

const pressureToWidth = 3      // 基准宽度 (px)
const minWidth = 1

function buildStroke(rawPoints) {
  const points = rawPoints.map((p, i) => [
    p.x,
    p.y,
    clamp(pressureOrSpeed(p), 0, 1)  // 压力/速度 → [0,1]
  ])
  const outline = getStroke(points, {
    size: pressureToWidth,
    thinning: 0.6,          // 压感瘦身程度
    smoothing: 0.5,         // 平滑度
    streamline: 0.5,        // 流线/简化
    simulatePressure: false // 真压感时关闭模拟
  })
  return new Path2D(outline.map(([x,y]) => [x,y]))
}
```

**曲线平滑算法选择**：
| 算法 | 特点 | 适用 |
|---|---|---|
| Chaikin 切割 | 简单、稳定、平滑毛毛角 | 通用默认 |
| Catmull-Rom 样条 | 过原始点、自然 | 忠实还原手写 |
| Bezier 二次/三次 | 控制点少、可编辑 | 图形规整 |

### 3.3 动态笔宽（速度/压力）
- 用 **pressure**（真压感）优先；无压感时用**移动速度**模拟（快→细，慢→粗）。
- 速度模拟公式：`width = base - k * speed`，clamp 到 `[minWidth, maxWidth]`。

### 3.4 橡皮擦三模式（官方 eraser）
| 模式 | 逻辑 |
|---|---|
| 笔画擦除（stroke） | 从笔画序列中删除与擦除路径相交的整段/点，重建曲线 |
| 像素擦除（pixel） | 按像素 alpha 擦除，破坏性 |
| 圆形擦除（circle） | 以触点为中心圆形区域擦除 |

对应 `onEraserEvent(points, size, mode)`。

### 3.5 图形笔（shape-pen）
手写后自动识别规整为形状（直线/矩形/圆/箭头/三角形等）。对应 `itemType` 区分，规整后仍为 Shape（可再次编辑顶点）。

### 3.6 胶带笔（tape-pen）— `tapeLike=true`
半透明遮盖层，用于闪卡/遮盖/重点高亮。区别于普通荧光笔：可一键"揭掉"（显示被盖内容）。

---

## 4. 局部重绘与性能

**`getBoundingBox` + `isRegionLoadable`** 是性能关键：

- 每个 DrawRecord 缓存 `bounds`（AABB）。
- 渲染时只重绘 **boundingBox intersect 脏区** 的内容项，而非整页。
- 页面支持区域按需加载（`isRegionLoadable`），超大画布（无界模式，最高 1600% 缩放）不会一次性加载全部。

```java
// 局部重绘伪代码
void onDirty(Rect dirtyRegion) {
    for (DrawRecord d : records) {
        if (d.bounds.intersect(dirtyRegion)) {
            d.render(canvas, clip=dirtyRegion);
        }
    }
}
```

---

## 5. Notein 产品功能全景（作用域核对）

官方功能与逆向代码**一一互证**，确认逆向架构完全真实：

| 官方功能 | 逆向依据 |
|---|---|
| 手写工具（钢笔/铅笔/荧光笔/彩虹笔） | `itemType` + brush 参数、压感/速度系数 |
| 橡皮擦三模式 | `onEraserEvent` 三模式 |
| 图形笔 | Shape type 枚举 |
| 胶带笔 | `tapeLike=true` |
| 激光笔（临时指示） | 独立 overlay 层，不入库 |
| 套索 | `onLassoEvent` + LassoParams |
| 图层系统 | PageLayer + LayerInfo + DEFAULT/PAPER_THEME |
| 手写转文本（VIP） | AI 模块（com.orion.notein/ai）|
| 录音回放同步 | audio-recording 模块，笔画关联时间戳 |

---

## 6. 给 Hydro Notes 的落地建议（从零实现，非复刻）

1. **统一内容模型**：所有页面项实现统一接口 `DisplayItem { getBounds(); render(canvas); deepCopy(); offset(); isHitTest(pt); isRegionLoadable(); }` — 这是局部重绘和多层架构的基石。
2. **层两套起步**：`paper`（底纸）+ `content`（内容），后续再加任意命名层。
3. **坐标用 Float，命中测试用缓存 AABB**：每个 item 缓存 bounds，局部脏区重绘。
4. **真压感优先，速度模拟兜底**：设备无压感（普通电容屏）时用速度模拟笔宽。
5. **渲染用 `perfect-freehand`（或自实现 outline 算法）+ Canvas/SVG**，别从零造笔刷轮子。
6. **橡皮擦 / 套索走几何运算**：笔画擦除=曲线裁剪；套索=AABB 粗筛 + 多边形包含精判。
7. **优先 Web/Electron 原型**：先做可交互的浏览器 demo（Canvas 手写 + 图层 + 橡皮擦），验证算法手感，再落地原生。

---

## 7. 参考数据文件位置

- 已反编译源码：`C:\Users\Admin\.easyclaw\workspace\hydro_decompiled\sources`
  - penkit 模型（真实类名）：`sources\com\orion\penkit\models\`
  - 页面模型：`sources\com\orion\notein\domain\models\page\`
- 布局文件列表：`C:\Users\Admin\.easyclaw\workspace\hydro_decompiled\layout_files.txt`
- 关键布局：`draw_panel_view.xml`（绘制面板）

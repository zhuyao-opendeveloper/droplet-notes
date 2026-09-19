# Hydro Note (Flutter)

离线、本地、流畅手写的 **PDF 阅读与注释** 工具。纯 Flutter 重写（替代原 Kotlin 版），统一 Android / iOS 代码库。

- 笔迹美化：`perfect_freehand`（平滑 + 压力笔宽 + 锥形收笔，对标 Notability 手感）
- PDF：导入用 `pdfx`（每页渲染为可书写背景），导出用 `pdf` + `printing`（背景+笔迹合成，扁平化）
- 图标：**Fluent UI System Icons**（`fluentui_system_icons`，微软开源，线性/填充两套）
- 完全离线：无网络权限、无分析、无广告

## 功能状态（详见 STATUS.md）

**✅ 已完成（第一阶段）**
- 本地文件库 / 多笔记本 / 自动保存
- 导入 PDF（逐页批注）
- 钢笔 / 毛笔 / 荧光笔 / 橡皮 / 形状（直线·矩形·椭圆·箭头）
- 手写笔压感、低延迟、防误触
- 撤销 / 重做
- 导出含注释 PDF
- 深色 / 浅色 / 护眼主题
- Fluent 图标风格切换（线性 / 填充，设置内）

**🔲 未完成（规划中）**
- 套索选择、图层管理、笔迹回放
- 文本工具 / 图片 / 便签
- 连续滚动 / 双页 / 缩放 / 大纲
- 纯 PDF / 图片导出、备份恢复
- 应用锁、iOS 真机验证、桌面端

## 运行 / 构建

```bash
flutter pub get
flutter run            # 调试
flutter build apk --release   # Android 发布包
flutter build ios      # 需 macOS + Xcode
```

iOS 工程需先生成原生骨架（本仓库未包含 xcodeproj）：
```bash
flutter create --platform=ios .
```

## CI

`.github/workflows/build.yml` 在 push 到 main 时自动用 GitHub Actions 构建 Android 发布 APK（产物为 artifact `app-release-apk`）。

## 目录

```
lib/
  models/        数据模型 (Note/Page/Stroke/Point/Tool)
  engine/        笔迹美化 Freehand.dart
  storage/       本地 JSON 存储 NoteStore.dart
  pdf/           PDF 导入 / 导出
  widgets/       手写画布 HandwritingCanvas
  ui/            主页 / 编辑器 / 设置
  theme.dart     主题 + 图标风格 + 全局设置
  main.dart      入口
```

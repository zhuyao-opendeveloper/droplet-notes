import 'package:flutter/material.dart';

/// 开源许可与致谢页。
///
/// 合规要点：使用 Apache License 2.0 组件（如 ML Kit）时需保留版权与许可声明，
/// 因此这里既给出可读的组件清单，也提供 Flutter 自动收集的**许可全文**入口。
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  static const _items = <List<String>>[
    [
      'Google ML Kit Text Recognition v2',
      'Apache License 2.0',
      '离线文字识别引擎（模型随应用打包，不联网）',
      'https://developers.google.com/ml-kit',
    ],
    [
      'perfect_freehand',
      'MIT License',
      '压感笔迹轮廓算法（Dart 移植版）',
      'https://pub.dev/packages/perfect_freehand',
    ],
    [
      'dart pdf / printing',
      'Apache License 2.0',
      'PDF 生成与导出',
      'https://pub.dev/packages/pdf',
    ],
    [
      'pdfx',
      'MIT License（内含 PDFium，BSD-3-Clause）',
      'PDF 页面渲染与导入',
      'https://pub.dev/packages/pdfx',
    ],
    [
      'Fluent UI System Icons',
      'MIT License',
      '界面图标（线性 / 填充双风格）',
      'https://github.com/microsoft/fluentui-system-icons',
    ],
    [
      'archive',
      'Apache License 2.0',
      '笔记库 ZIP 备份与恢复',
      'https://pub.dev/packages/archive',
    ],
    [
      'record / audioplayers',
      'BSD-3-Clause / MIT',
      '录音与音频回放',
      'https://pub.dev/packages/record',
    ],
    [
      'Flutter SDK',
      'BSD-3-Clause',
      '应用框架',
      'https://flutter.dev',
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('开源许可')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Hydro Note 使用了以下开源组件。相关组件按其许可协议（多为 '
                'Apache License 2.0 / MIT / BSD）授权，允许商业使用；'
                '本应用保留其版权与许可声明。',
                style: TextStyle(height: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 10),
          for (final it in _items)
            Card(
              elevation: 1,
              margin: const EdgeInsets.only(bottom: 8),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: ListTile(
                title: Text(it[0],
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text(it[1]),
                    Text(it[2],
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(it[3],
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.blueGrey)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('查看许可协议全文'),
              subtitle: const Text('由 Flutter 自动收集全部依赖的 LICENSE 原文'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Hydro Note',
                applicationLegalese: '离线手写笔记 · 本地优先',
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

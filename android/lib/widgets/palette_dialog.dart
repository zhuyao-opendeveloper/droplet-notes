import 'package:flutter/material.dart';

import '../data/palettes.dart';

/// 颜色选择对话框：标签页切换「彩虹 6×4 / 现代 / 复古 / 黑白」四组预设，
/// 点选返回对应颜色的 hex 字符串（如 #1F59FF）。
class PaletteDialog extends StatefulWidget {
  const PaletteDialog({super.key});

  @override
  State<PaletteDialog> createState() => _PaletteDialogState();
}

class _PaletteDialogState extends State<PaletteDialog> {
  int _tab = 0;

  static Color _parse(String hex) =>
      Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);

  @override
  Widget build(BuildContext context) {
    final groups = Palettes.groups;
    final g = groups[_tab];
    return AlertDialog(
      title: const Text('选择颜色'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: groups.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ChoiceChip(
                  label: Text(groups[i].name),
                  selected: _tab == i,
                  onSelected: (_) => setState(() => _tab = i),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: g.colors
                  .map(
                    (hex) => GestureDetector(
                      onTap: () => Navigator.pop(context, hex),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _parse(hex),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.black12),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

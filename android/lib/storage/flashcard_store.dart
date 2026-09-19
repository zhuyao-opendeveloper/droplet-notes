import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/flashcard.dart';

/// 闪卡存储：每本笔记一个 <id>.json，放在 notes/cards/ 子目录，纯本地、无网络。
///
/// 必须放在子目录而不是 notes/ 根目录：笔记列表是扫 notes/ 下所有 .json 得到的，
/// 闪卡文件同样以 .json 结尾却不是 Note（没有 id / pages 字段），会被笔记扫描
/// 当成「损坏的笔记」隔离改名，用户辛苦做的闪卡就凭空消失了。
class FlashCardStore {
  static Future<File> _file(String noteId) async {
    final dir =
        Directory('${(await getApplicationDocumentsDirectory()).path}/notes/cards');
    return File('${dir.path}/$noteId.json');
  }

  /// 老版本的路径：notes/<id>_cards.json（与笔记文件混在同一目录）。
  /// 只在读取回退与一次性迁移时使用，新数据一律写 notes/cards/。
  static Future<File> _legacyFile(String noteId) async {
    final dir =
        Directory('${(await getApplicationDocumentsDirectory()).path}/notes');
    return File('${dir.path}/${noteId}_cards.json');
  }

  static Future<FlashCardDeck> load(String noteId) async {
    final f = await _file(noteId);
    if (!await f.exists()) {
      // 换过存储目录，老用户的卡还在旧路径上。不回退读取的话，升级后
      // 所有历史卡片会「凭空消失」—— 这才是真正不可接受的数据丢失。
      final old = await _legacyFile(noteId);
      if (await old.exists()) {
        final deck = await _read(old, noteId);
        if (deck != null) {
          // 顺手搬到新位置，下次直接命中新路径
          await save(deck);
          try {
            await old.delete();
          } catch (_) {}
          return deck;
        }
      }
      return FlashCardDeck(noteId: noteId, cards: []);
    }
    return await _read(f, noteId) ?? FlashCardDeck(noteId: noteId, cards: []);
  }

  /// 读单个卡组文件；损坏 / 读不出来返回 null（不吞成空卡组，
  /// 免得把「读失败」误当成「用户没做过卡」而触发覆盖写）。
  static Future<FlashCardDeck?> _read(File f, String noteId) async {
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final deck = FlashCardDeck.fromJson(j);
      return deck.copyWith(cards: deck.cards);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(FlashCardDeck deck) async {
    final f = await _file(deck.noteId);
    // notes/cards/ 在老版本上并不存在，必须先建；否则 writeAsString 直接抛
    // 「No such file or directory」，用户以为卡片存了其实一次都没落盘。
    await f.parent.create(recursive: true);
    // 原子写：直接覆盖写若中途被杀（切后台被回收 / 没电），会留下半截 JSON，
    // load() 的 catch 会静默返回空卡组 —— 用户做的卡全没了且没有任何提示。
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(deck.toJson()));
    try {
      await tmp.rename(f.path);
    } catch (_) {
      // Windows 的 rename 不允许覆盖已存在文件
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  }

  static String newId() => const Uuid().v4();
}

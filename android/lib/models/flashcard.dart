/// 闪卡模型 + SM-2 间隔重复调度。纯本地、无网络。
class FlashCard {
  final String id;
  final String front;
  final String back;
  int due; // 到期时间戳（ms），<=now 表示待复习
  double ease; // SM-2 易度因子（>=1.3）
  int interval; // 复习间隔（天）
  int reps; // 连续答对次数

  FlashCard({
    required this.id,
    required this.front,
    required this.back,
    int? due,
    this.ease = 2.5,
    this.interval = 0,
    this.reps = 0,
  }) : due = due ?? DateTime.now().millisecondsSinceEpoch;

  FlashCard copyWith({
    String? id,
    String? front,
    String? back,
    int? due,
    double? ease,
    int? interval,
    int? reps,
  }) =>
      FlashCard(
        id: id ?? this.id,
        front: front ?? this.front,
        back: back ?? this.back,
        due: due ?? this.due,
        ease: ease ?? this.ease,
        interval: interval ?? this.interval,
        reps: reps ?? this.reps,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'front': front,
        'back': back,
        'due': due,
        'ease': ease,
        'iv': interval,
        'reps': reps,
      };

  factory FlashCard.fromJson(Map<String, dynamic> j) => FlashCard(
        id: j['id'] as String,
        front: (j['front'] as String?) ?? '',
        back: (j['back'] as String?) ?? '',
        due: (j['due'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
        ease: (j['ease'] as num? ?? 2.5).toDouble(),
        interval: (j['iv'] as int?) ?? 0,
        reps: (j['reps'] as int?) ?? 0,
      );
}

class FlashCardDeck {
  final String noteId;
  final List<FlashCard> cards;

  const FlashCardDeck({required this.noteId, required this.cards});

  FlashCardDeck copyWith({List<FlashCard>? cards}) =>
      FlashCardDeck(noteId: noteId, cards: cards ?? this.cards);

  Map<String, dynamic> toJson() => {
        'noteId': noteId,
        'cards': cards.map((c) => c.toJson()).toList(),
      };

  factory FlashCardDeck.fromJson(Map<String, dynamic> j) => FlashCardDeck(
        noteId: (j['noteId'] as String?) ?? '',
        cards: (j['cards'] as List? ?? [])
            .map((e) => FlashCard.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// SM-2 调度：quality 0..5（again=2, hard=3, good=4, easy=5）。
void scheduleSm2(FlashCard card, int quality) {
  if (quality < 3) {
    card.reps = 0;
    card.interval = 0;
    card.due = DateTime.now().millisecondsSinceEpoch;
    return;
  }
  if (card.reps == 0) {
    card.interval = 1;
  } else if (card.reps == 1) {
    card.interval = 6;
  } else {
    card.interval = (card.interval * card.ease).round();
  }
  card.ease += 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02);
  if (card.ease < 1.3) card.ease = 1.3;
  card.reps += 1;
  card.due = DateTime.now()
          .add(Duration(days: card.interval))
          .millisecondsSinceEpoch;
}

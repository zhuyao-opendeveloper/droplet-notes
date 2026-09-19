class Layer {
  final String id;
  final String name;
  final bool visible;

  const Layer({required this.id, required this.name, this.visible = true});

  Layer copyWith({String? id, String? name, bool? visible}) => Layer(
        id: id ?? this.id,
        name: name ?? this.name,
        visible: visible ?? this.visible,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'v': visible};

  factory Layer.fromJson(Map<String, dynamic> j) => Layer(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '图层',
        visible: (j['v'] as bool?) ?? true,
      );

  static const String defaultId = 'content';
}

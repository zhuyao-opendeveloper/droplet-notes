class Point {
  final double x;
  final double y;
  final double pressure;

  const Point(this.x, this.y, [this.pressure = 0.5]);

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'p': pressure,
      };

  factory Point.fromJson(Map<String, dynamic> j) =>
      Point((j['x'] as num).toDouble(), (j['y'] as num).toDouble(),
          (j['p'] as num? ?? 0.5).toDouble());
}

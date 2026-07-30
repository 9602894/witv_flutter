class Subscription {
  final String name;
  final String url;
  bool selected;

  Subscription({required this.name, required this.url, this.selected = false});

  Map<String, dynamic> toJson() => {'name': name, 'url': url, 'selected': selected};
  factory Subscription.fromJson(Map<String, dynamic> json) =>
      Subscription(name: json['name'], url: json['url'], selected: json['selected'] ?? false);
}

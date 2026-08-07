class Channel {
  final String name;
  final String url;
  final String group;
  final String? logoUrl;
  final int? number; // 频道号

  Channel({
    required this.name,
    required this.url,
    required this.group,
    this.logoUrl,
    this.number,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Channel &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          url == other.url;

  @override
  int get hashCode => name.hashCode ^ url.hashCode;
}

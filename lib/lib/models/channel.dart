class Channel {
  final String name;
  final String url;
  final String group;
  final String? logoUrl;

  Channel({required this.name, required this.url, required this.group, this.logoUrl});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Channel && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;
}

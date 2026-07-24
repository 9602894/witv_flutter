class EpgProgram {
  final DateTime start;
  final DateTime end;
  final String title;
  final String? desc;

  EpgProgram({required this.start, required this.end, required this.title, this.desc});
}
